"""Exercise the retained JSON/HLS fixture; this does not validate iOS decoding."""
import http.client
import json
import re
import subprocess
import time
from pathlib import Path

root = Path(__file__).resolve().parent.parent
media = root / "Tests/source2-hls"
media.mkdir(exist_ok=True)
subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(root / "Tests/sample.mp4"),
    "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-t", "6", "-f", "hls", "-hls_time", "3",
    "-hls_list_size", "0", "-hls_base_url", "/source2-hls/", str(media / "index.m3u8"),
], check=True)
server = subprocess.Popen(["python3", str(root / "Tests/serve_player.py"), "--source2-hls"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def request(path, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", 8765, timeout=2)
    try:
        connection.request("GET", path, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()

try:
    for _ in range(40):
        if server.poll() is not None:
            raise RuntimeError("The fixture could not bind port 8765")
        try:
            status, body = request("/__health")
            health = json.loads(body)
            assert status == 200 and health["service"] == "anpinime-media-fixture" and health["pid"] == server.pid and health["relayHLS"]
            break
        except (OSError, ValueError):
            time.sleep(0.05)
    else:
        raise RuntimeError("Fixture readiness timed out")
    status, body = request("/danh-sach/phim-moi-cap-nhat-v3")
    assert status == 200 and json.loads(body)["items"][0]["slug"] == "legacy"
    status, body = request("/phim/legacy")
    assert status == 200 and "/api/content/stream/hls" in json.loads(body)["episodes"][0]["server_data"][0]["link"]
    assert request("/api/content/stream/hls")[0] == 403
    agent = re.search(r'static let userAgent = "([^"]+)"', (root / "AnyAnime/AnimeService.swift").read_text()).group(1)
    headers = {"User-Agent": agent, "Referer": "http://127.0.0.1:8765/", "Origin": "http://127.0.0.1:8765"}
    status, body = request("/api/content/stream/hls", headers)
    assert status == 200 and body.startswith(b"#EXTM3U")
    segment = next(line for line in body.decode().splitlines() if line and not line.startswith("#"))
    status, segment_body = request(segment, headers)
    assert status == 200 and len(segment_body) > 188 and segment_body[0] == 0x47
    assert request("/api/content/stream/hls", dict(headers, Authorization="fixture"))[0] == 403
    print("PASS: shared JSON/HLS fixture identity, catalog, selected episode, required headers, credential rejection and actual MPEG-TS bytes")
finally:
    server.terminate()
    server.wait(timeout=5)
