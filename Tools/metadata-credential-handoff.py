#!/usr/bin/env python3
"""One-run encrypted metadata handoff when Actions secrets are unavailable.

The runner retains a temporary RSA private key. Only its public challenge and
an OAEP ciphertext leave the machine. This module never prints credential data.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


TIMEOUT_SECONDS = 180
MAX_PACKET_BYTES = 16 * 1024


class HandoffError(Exception):
    pass


def context(environment):
    result = {
        "repository": environment.get("GITHUB_REPOSITORY", ""),
        "sourceCommit": environment.get("GITHUB_SHA", ""),
        "runID": environment.get("GITHUB_RUN_ID", ""),
        "runAttempt": environment.get("GITHUB_RUN_ATTEMPT", "1"),
    }
    if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", result["repository"])
            or not re.fullmatch(r"[a-f0-9]{40}", result["sourceCommit"])
            or not re.fullmatch(r"[1-9][0-9]{0,19}", result["runID"])
            or not re.fullmatch(r"[1-9][0-9]{0,3}", result["runAttempt"])):
        raise HandoffError("Invalid Actions handoff context.")
    return result


def handoff_branch(ctx):
    return "automation/metadata-handoff-" + ctx["runID"] + "-" + ctx["runAttempt"]


def artifact_name(ctx):
    return "Metadata-public-key-" + ctx["runID"] + "-" + ctx["runAttempt"]


def openssl(arguments, data=None):
    result = subprocess.run(["openssl"] + arguments, input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise HandoffError("Metadata handoff cryptographic operation failed.")
    return result.stdout


def write_private(path, data):
    with path.open("xb") as output:
        os.chmod(path, 0o600)
        output.write(data)


def create(directory, ctx, now=None):
    now = int(time.time() if now is None else now)
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / "public").mkdir(mode=0o700)
    private = directory / "private.pem"
    write_private(private, openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072"]))
    public = openssl(["pkey", "-in", str(private), "-pubout"])
    request = dict(ctx, version=1, requestID=uuid.uuid4().hex,
                   createdAt=now, expiresAt=now + TIMEOUT_SECONDS,
                   publicKey=public.decode("ascii"), publicKeySHA256=hashlib.sha256(public).hexdigest())
    (directory / "public" / "request.json").write_text(json.dumps(request) + "\n")
    return request


def validate_request(request, ctx, now=None):
    now = int(time.time() if now is None else now)
    if (not isinstance(request, dict) or request.get("version") != 1
            or any(request.get(k) != v for k, v in ctx.items())
            or not re.fullmatch(r"[a-f0-9]{32}", str(request.get("requestID", "")))
            or not isinstance(request.get("createdAt"), int)
            or not isinstance(request.get("expiresAt"), int)
            or not request["createdAt"] - 15 <= now < request["expiresAt"]
            or request["expiresAt"] - request["createdAt"] != TIMEOUT_SECONDS):
        raise HandoffError("Metadata handoff challenge is expired or belongs to another build.")
    public_text = request.get("publicKey", "")
    if not isinstance(public_text, str):
        raise HandoffError("Metadata handoff public key is invalid.")
    public = public_text.encode("ascii")
    if len(public) > 2048 or hashlib.sha256(public).hexdigest() != request.get("publicKeySHA256"):
        raise HandoffError("Metadata handoff public key is invalid.")
    return request


def validate_config(config):
    if (not isinstance(config, dict) or not config
            or set(config) - {"TMDB_API_KEY", "TMDB_READ_TOKEN"}):
        raise HandoffError("Metadata handoff credential configuration is invalid.")
    for name, value in config.items():
        if (not isinstance(value, str) or not value or len(value.encode()) > 8192
                or any(character.isspace() for character in value)
                or (name == "TMDB_API_KEY" and not re.fullmatch(r"[a-fA-F0-9]{32}", value))):
            raise HandoffError("Metadata handoff credential format is invalid.")
    return config


def encrypt(request, ctx, config, public_path, now=None):
    validate_request(request, ctx, now)
    validate_config(config)
    public_path.write_text(request["publicKey"])
    plaintext = json.dumps({"v": 1, "request": request["requestID"], "sha": ctx["sourceCommit"],
                            "run": ctx["runID"], "attempt": ctx["runAttempt"], "config": config},
                           separators=(",", ":")).encode()
    # OAEP SHA-256 with a 3072-bit key supports at most 318 plaintext bytes.
    if len(plaintext) > 318:
        raise HandoffError("Credential is too large for this one-run handoff; configure an Actions secret instead.")
    ciphertext = openssl(["pkeyutl", "-encrypt", "-pubin", "-inkey", str(public_path),
                          "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
                          "-pkeyopt", "rsa_mgf1_md:sha256"], plaintext)
    return dict(ctx, version=1, requestID=request["requestID"],
                publicKeySHA256=request["publicKeySHA256"], ciphertext=base64.b64encode(ciphertext).decode())


def decrypt(directory, packet, ctx, now=None):
    request = json.loads((directory / "public" / "request.json").read_text())
    validate_request(request, ctx, now)
    if (not isinstance(packet, dict) or packet.get("version") != 1
            or any(packet.get(k) != v for k, v in ctx.items())
            or packet.get("requestID") != request["requestID"]
            or packet.get("publicKeySHA256") != request["publicKeySHA256"]):
        raise HandoffError("Encrypted metadata packet belongs to another build.")
    try:
        ciphertext = base64.b64decode(packet["ciphertext"], validate=True)
    except (KeyError, ValueError, TypeError):
        raise HandoffError("Encrypted metadata packet is malformed.") from None
    if len(ciphertext) != 384:
        raise HandoffError("Encrypted metadata packet has an invalid size.")
    plaintext = openssl(["pkeyutl", "-decrypt", "-inkey", str(directory / "private.pem"),
                         "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
                         "-pkeyopt", "rsa_mgf1_md:sha256"], ciphertext)
    try:
        payload = json.loads(plaintext)
    except (ValueError, UnicodeError):
        raise HandoffError("Decrypted metadata packet is malformed.") from None
    if (not isinstance(payload, dict) or payload.get("v") != 1 or payload.get("request") != request["requestID"]
            or payload.get("sha") != ctx["sourceCommit"] or payload.get("run") != ctx["runID"]
            or payload.get("attempt") != ctx["runAttempt"] or not isinstance(payload.get("config"), dict)
            or set(payload["config"]) - {"TMDB_API_KEY", "TMDB_READ_TOKEN"}):
        raise HandoffError("Decrypted metadata packet failed build binding checks.")
    return validate_config(payload["config"])


def fetch_packet(ctx, token, timeout=10):
    query = urllib.parse.urlencode({"ref": handoff_branch(ctx)})
    url = "https://api.github.com/repos/" + ctx["repository"] + "/contents/.automation/metadata-handoff.json?" + query
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = response.read(MAX_PACKET_BYTES + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise HandoffError("Cannot read the encrypted metadata handoff from GitHub.") from None
    except OSError:
        raise HandoffError("Cannot reach GitHub for the encrypted metadata handoff.") from None
    try:
        if len(data) > MAX_PACKET_BYTES:
            raise ValueError()
        wrapper = json.loads(data)
        if not isinstance(wrapper, dict):
            raise ValueError()
        return json.loads(base64.b64decode(wrapper["content"], validate=False))
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise HandoffError("GitHub returned an invalid encrypted metadata packet.") from None


def wait_for_packet(ctx, token, expires_at, fetch=fetch_packet, clock=time.time, sleep=time.sleep):
    while clock() < expires_at:
        packet = fetch(ctx, token, timeout=min(10, max(0.1, expires_at - clock())))
        if packet is not None and clock() < expires_at:
            return packet
        sleep(min(2, max(0, expires_at - clock())))
    raise HandoffError("Encrypted metadata handoff timed out; no build retry was requested.")


def cleanup(directory):
    if directory.exists():
        shutil.rmtree(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "receive", "cleanup"))
    args = parser.parse_args()
    directory = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "anpinime-metadata-handoff"
    try:
        if args.action == "cleanup":
            cleanup(directory)
            return 0
        ctx = context(os.environ)
        if args.action == "create":
            create(directory, ctx)
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write("handoff=true\nartifact=" + artifact_name(ctx) + "\n")
            print("Ephemeral public challenge prepared; waiting for the workspace's encrypted metadata packet.")
            return 0
        try:
            request = json.loads((directory / "public" / "request.json").read_text())
            validate_request(request, ctx)
            packet = wait_for_packet(ctx, os.environ["GITHUB_TOKEN"], request["expiresAt"])
            config = decrypt(directory, packet, ctx)
            environment = dict(os.environ)
            environment.pop("TMDB_API_KEY", None)
            environment.pop("TMDB_READ_TOKEN", None)
            environment.update(config)
            script = Path(__file__).with_name("prepare-metadata-credentials.py")
            subprocess.run([sys.executable, str(script)], env=environment, check=True)
            print("Encrypted metadata handoff completed for this build.")
            return 0
        finally:
            cleanup(directory)
    except (HandoffError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(str(error) if isinstance(error, HandoffError) else "Metadata handoff failed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
