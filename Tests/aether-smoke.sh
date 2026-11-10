#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ANPINIME_SWIFTC=${ANPINIME_SWIFTC:-swiftc}
ANPINIME_AETHER_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/anpinime-aether-tests.XXXXXX")
trap 'rm -rf "$ANPINIME_AETHER_TEMP"' EXIT
"$ANPINIME_SWIFTC" AnyAnime/Aether/AetherDomainResolver.swift Tests/AetherDomainResolverTests.swift -o "$ANPINIME_AETHER_TEMP/domains"
"$ANPINIME_AETHER_TEMP/domains"
"$ANPINIME_SWIFTC" AnyAnime/Models.swift AnyAnime/SearchHistory.swift AnyAnime/MovieSourceMigration.swift \
  AnyAnime/WebPiPSessionState.swift \
  Tests/AetherIntegrationTests.swift -o "$ANPINIME_AETHER_TEMP/integration"
"$ANPINIME_AETHER_TEMP/integration"
"$ANPINIME_SWIFTC" AnyAnime/Models.swift AnyAnime/MovieSourceProviding.swift \
  AnyAnime/Aether/AetherDomainResolver.swift AnyAnime/Aether/AetherMetadataSettings.swift \
  AnyAnime/Aether/AetherCatalog.swift AnyAnime/Aether/AetherProvider.swift \
  Tests/AetherCatalogTests.swift -o "$ANPINIME_AETHER_TEMP/catalog"
"$ANPINIME_AETHER_TEMP/catalog"
