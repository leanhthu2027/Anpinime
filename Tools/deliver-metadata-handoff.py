#!/usr/bin/env python3
"""Deliver a private local plist to one exact running IPA job using RSA OAEP.

Run after an explicitly authorized build dispatch. This command never starts
or retries workflows. It publishes ciphertext only, on a unique run branch.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time


spec = importlib.util.spec_from_file_location("handoff", Path(__file__).with_name("metadata-credential-handoff.py"))
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


def gh(arguments, data=None, missing_ok=False):
    result = subprocess.run(["gh"] + arguments, input=None if data is None else json.dumps(data),
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        if missing_ok and "HTTP 404" in result.stderr:
            return None
        raise handoff.HandoffError("GitHub operation failed; the workflow was not dispatched or retried by this command.")
    return json.loads(result.stdout) if result.stdout.strip() else None


def api(path, method="GET", data=None, missing_ok=False):
    arguments = ["api", "--method", method, path]
    if data is not None:
        arguments += ["--input", "-"]
    return gh(arguments, data, missing_ok)


def deliver(repository, run_id, source_sha, source_file):
    root = "repos/" + repository
    run = api(root + "/actions/runs/" + run_id)
    if (run.get("head_sha") != source_sha or run.get("event") != "workflow_dispatch"
            or run.get("path") != ".github/workflows/build-ipa-light.yml"
            or run.get("status") == "completed"):
        raise handoff.HandoffError("Refusing metadata delivery to a different, completed, or non-IPA run.")
    ctx = handoff.context({"GITHUB_REPOSITORY": repository, "GITHUB_SHA": source_sha,
                           "GITHUB_RUN_ID": run_id, "GITHUB_RUN_ATTEMPT": str(run["run_attempt"])})
    name = handoff.artifact_name(ctx)
    deadline = time.monotonic() + 150
    artifact = None
    while time.monotonic() < deadline:
        artifacts = api(root + "/actions/runs/" + run_id + "/artifacts?per_page=100")["artifacts"]
        matches = [item for item in artifacts if item["name"] == name and not item["expired"]]
        if len(matches) > 1:
            raise handoff.HandoffError("Multiple public challenges exist for this run; refusing delivery.")
        if matches:
            artifact = matches[0]
            break
        run = api(root + "/actions/runs/" + run_id)
        if run["status"] == "completed":
            raise handoff.HandoffError("IPA run completed without requesting metadata handoff.")
        time.sleep(2)
    if artifact is None or artifact["size_in_bytes"] > 16 * 1024:
        raise handoff.HandoffError("Public metadata challenge is missing or too large.")
    with tempfile.TemporaryDirectory(prefix="anpinime-metadata-delivery-") as temporary:
        directory = Path(temporary)
        download = subprocess.run(["gh", "run", "download", run_id, "--repo", repository,
                                   "--name", name, "--dir", str(directory)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if download.returncode:
            raise handoff.HandoffError("Could not download the public metadata challenge.")
        request_path = directory / "request.json"
        if not request_path.is_file() or request_path.stat().st_size > 8192:
            raise handoff.HandoffError("Public metadata challenge is malformed.")
        request = json.loads(request_path.read_text())
        handoff.validate_request(request, ctx)
        if source_file.stat().st_size > 32 * 1024:
            raise handoff.HandoffError("Private metadata resource is too large.")
        config = plistlib.loads(source_file.read_bytes())
        packet = handoff.encrypt(request, ctx, config, directory / "public.pem")
        branch = handoff.handoff_branch(ctx)
        reference = api(root + "/git/ref/heads/" + branch, missing_ok=True)
        if reference is None:
            api(root + "/git/refs", "POST", {"ref": "refs/heads/" + branch, "sha": source_sha})
        elif reference["object"]["sha"] != source_sha:
            raise handoff.HandoffError("Handoff branch already contains a response; refusing overwrite.")
        handoff.validate_request(request, ctx)  # Recheck expiry immediately before publishing.
        import base64
        api(root + "/contents/.automation/metadata-handoff.json", "PUT", {
            "message": "Deliver encrypted metadata to IPA run " + run_id,
            "branch": branch,
            "content": base64.b64encode((json.dumps(packet) + "\n").encode()).decode(),
        })
        print("Encrypted metadata delivered to IPA run " + run_id + "; no workflow was dispatched or retried.")
        print("Ciphertext branch: " + branch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--credential-file", type=Path, required=True)
    args = parser.parse_args()
    try:
        handoff.context({"GITHUB_REPOSITORY": args.repository, "GITHUB_SHA": args.source_sha,
                         "GITHUB_RUN_ID": args.run_id})
        deliver(args.repository, args.run_id, args.source_sha, args.credential_file)
        return 0
    except handoff.HandoffError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        # Never format an exception containing a private configuration or input.
        print("Encrypted metadata delivery failed. Check the run's public challenge, permissions, and deadline.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
