#!/usr/bin/env bash
set -euo pipefail
ANPINIME_RESULT=relay-hls
ANPINIME_FLAG=--relay-hls-smoke
ANPINIME_EXTRA_ARGS=(--mpv-playback-smoke)
ANPINIME_MIN_PLAYBACK_SECONDS=1
cleanup() {
  if [ -n "${ANPINIME_SIMULATOR_ID:-}" ]; then
    xcrun simctl terminate "$ANPINIME_SIMULATOR_ID" com.xemphim.aipinime >/dev/null 2>&1 || true
  fi
  if [ -n "${ANPINIME_SERVER_PID:-}" ]; then
    kill "$ANPINIME_SERVER_PID" || true
    wait "$ANPINIME_SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
  mkdir -p Tests/source2-hls
  ffmpeg -hide_banner -loglevel error -y -i Tests/multitrack.mkv -map 0:v:0 -map 0:a:0 -c copy -t 12 -f hls -hls_time 3 -hls_list_size 0 -hls_base_url /source2-hls/ Tests/source2-hls/index.m3u8
  python3 Tests/serve_player.py --source2-hls > "$RUNNER_TEMP/anpinime-source2-hls-server.log" 2>&1 &
  ANPINIME_SERVER_PID=$!
  ANPINIME_READY=0
  for attempt in $(seq 1 20); do
    if python3 - "$ANPINIME_SERVER_PID" <<'PYHEALTH'
import http.client, json, sys
try:
    c=http.client.HTTPConnection('127.0.0.1',8765,timeout=1)
    c.request('GET','/__health'); r=c.getresponse(); v=json.loads(r.read())
    assert r.status==200 and v['service']=='anpinime-media-fixture' and v['pid']==int(sys.argv[1]) and v['relayHLS']
except (OSError,ValueError,AssertionError,KeyError): sys.exit(1)
PYHEALTH
    then ANPINIME_READY=1; break; fi
    kill -0 "$ANPINIME_SERVER_PID"
    sleep 1
  done
  test "$ANPINIME_READY" = 1
ANPINIME_SIMULATOR_ID=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if "iPhone" in d["name"]))')
ANPINIME_APP_DATA=$(xcrun simctl get_app_container "$ANPINIME_SIMULATOR_ID" com.xemphim.aipinime data)
python3 - "$ANPINIME_APP_DATA" "$ANPINIME_RESULT" <<'PY'
from pathlib import Path
import sys
for directory in (Path(sys.argv[1])/'Documents', Path('previews')):
    for suffix in ('', '-diagnostics'):
        (directory/('playback-'+sys.argv[2]+suffix+'.json')).unlink(missing_ok=True)
PY
xcrun simctl launch --terminate-running-process "$ANPINIME_SIMULATOR_ID" com.xemphim.aipinime "$ANPINIME_FLAG" "${ANPINIME_EXTRA_ARGS[@]}"
for attempt in $(seq 1 75); do
  if [ -f "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT.json" ]; then
    # Wait for the requested media time, independently of first-frame timing.
    if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["time"]>=float(sys.argv[2]) else 1)' "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT.json" "$ANPINIME_MIN_PLAYBACK_SECONDS"; then break; fi
  fi
  if [ -f "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT-diagnostics.json" ] && python3 -c 'import json,sys; sys.exit(0 if any(e["event"]=="failure" for e in json.load(open(sys.argv[1]))["events"]) else 1)' "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT-diagnostics.json"; then break; fi
  sleep 1
done
mkdir -p previews
xcrun simctl io "$ANPINIME_SIMULATOR_ID" screenshot "previews/$ANPINIME_RESULT.png"
if [ -f "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT-diagnostics.json" ]; then
  cp "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT-diagnostics.json" previews/
  cat "previews/playback-$ANPINIME_RESULT-diagnostics.json"
fi
if [ ! -f "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT.json" ]; then
  echo "### $ANPINIME_RESULT: FAIL — no verified video playback" >> "$GITHUB_STEP_SUMMARY"
  exit 1
fi
cp "$ANPINIME_APP_DATA/Documents/playback-$ANPINIME_RESULT.json" previews/
cp "$RUNNER_TEMP/anpinime-source2-hls-server.log" previews/
python3 - <<'PYTEST'
import json
r=json.load(open('previews/playback-relay-hls.json'))
assert r['backend']=='mpv' and r['advancingVideoVerified'] and r['videoWidth']>0 and r['videoHeight']>0 and r['time']>1 and r['landscape'], r
print('PASS: shared HLS relay decoded and advancing')
PYTEST
