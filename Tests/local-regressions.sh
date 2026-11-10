#!/usr/bin/env bash
# Offline unit/fixture checks. Requires Swift, Python 3 and Node + jsdom@26.1.0.
# Does not dispatch Actions, build iOS, or contact live content providers.
set -euo pipefail
cd "$(dirname "$0")/.."
ANPINIME_SWIFTC=${ANPINIME_SWIFTC:-swiftc}
ANPINIME_NODE=${ANPINIME_NODE:-node}
ANPINIME_CHECK_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/anpinime-local-tests.XXXXXX")
ANPINIME_RANGE_SERVER=""
cleanup() {
    if [ -n "$ANPINIME_RANGE_SERVER" ]; then
        kill "$ANPINIME_RANGE_SERVER" 2>/dev/null || true
        wait "$ANPINIME_RANGE_SERVER" 2>/dev/null || true
    fi
    rm -rf "$ANPINIME_CHECK_TEMP"
}
trap cleanup EXIT

bash Tests/aether-smoke.sh
"$ANPINIME_SWIFTC" AnyAnime/NativePiPPolicy.swift Tests/NativePiPPolicyTests.swift -o "$ANPINIME_CHECK_TEMP/pip"
"$ANPINIME_CHECK_TEMP/pip"
"$ANPINIME_NODE" Tests/player.test.cjs
"$ANPINIME_NODE" Tests/aether-player.test.cjs

ANPINIME_PARSER=(AnyAnime/Models.swift AnyAnime/AnimeSiteConfiguration.swift AnyAnime/HTMLDocument.swift AnyAnime/HTMLParser.swift AnyAnime/MovieBrowseCatalog.swift AnyAnime/MovieCatalog.swift)
"$ANPINIME_SWIFTC" "${ANPINIME_PARSER[@]}" AnyAnime/AnimeScheduleStore.swift AnyAnime/Phim4KRelayNaming.swift AnyAnime/SearchHistory.swift AnyAnime/FilmMediaTransform.swift Tests/main.swift -o "$ANPINIME_CHECK_TEMP/parser"
"$ANPINIME_CHECK_TEMP/parser"
"$ANPINIME_SWIFTC" "${ANPINIME_PARSER[@]}" AnyAnime/MovieSourceProviding.swift AnyAnime/MovieProvider.swift AnyAnime/Phim4KTransportPolicy.swift Tests/ProviderTests.swift -o "$ANPINIME_CHECK_TEMP/providers"
"$ANPINIME_CHECK_TEMP/providers"
bash Tests/anime-home-smoke.sh
"$ANPINIME_SWIFTC" AnyAnime/AIDrama/AIDramaModels.swift AnyAnime/AIDrama/PineDramaProvider.swift Tests/AIDramaProviderTests.swift -o "$ANPINIME_CHECK_TEMP/ai-provider"
"$ANPINIME_CHECK_TEMP/ai-provider"

"$ANPINIME_SWIFTC" AnyAnime/Phim4KTransportPolicy.swift AnyAnime/Phim4KMediaProbe.swift Tests/RangeProbeTests.swift -o "$ANPINIME_CHECK_TEMP/range"
ANPINIME_RANGE_PORT=0 ANPINIME_RANGE_READY_FILE="$ANPINIME_CHECK_TEMP/ready.json" python3 -u Tests/range_probe_server.py > "$ANPINIME_CHECK_TEMP/range-server.log" 2>&1 &
ANPINIME_RANGE_SERVER=$!
ANPINIME_RANGE_PORT=$(python3 Tests/range_fixture_ready.py --pid "$ANPINIME_RANGE_SERVER" --ready-file "$ANPINIME_CHECK_TEMP/ready.json")
export ANPINIME_RANGE_PORT
"$ANPINIME_CHECK_TEMP/range"
python3 Tests/range_virtual_test.py

# Parsing catches Swift syntax only; it is NOT an Apple SDK typecheck/build.
ANPINIME_SOURCES=()
while IFS= read -r -d '' source; do ANPINIME_SOURCES+=("$source"); done < <(find AnyAnime -name '*.swift' -print0)
"$ANPINIME_SWIFTC" -parse "${ANPINIME_SOURCES[@]}"
git diff --check
echo 'PASS: offline local regressions completed; iOS build/playback/PiP still require Apple runtime validation'
