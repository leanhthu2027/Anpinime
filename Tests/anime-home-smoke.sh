#!/usr/bin/env bash
set -euo pipefail
ANPINIME_SWIFTC=${ANPINIME_SWIFTC:-swiftc}
ANPINIME_HOME_TEST_BINARY=$(mktemp "${TMPDIR:-/tmp}/anpinime-home-tests.XXXXXX")
trap 'rm -f "$ANPINIME_HOME_TEST_BINARY"' EXIT
"$ANPINIME_SWIFTC" -parse-as-library AnyAnime/Models.swift AnyAnime/AnimeSiteConfiguration.swift \
  AnyAnime/AnimeScheduleStore.swift AnyAnime/AnimeHomeStore.swift AnyAnime/HTMLDocument.swift \
  AnyAnime/HTMLParser.swift AnyAnime/DomainResolver.swift AnyAnime/AnimeService.swift \
  AnyAnime/MovieSourceProviding.swift AnyAnime/MovieSourceMigration.swift \
  AnyAnime/Aether/AetherDomainResolver.swift AnyAnime/Aether/AetherMetadataSettings.swift \
  AnyAnime/Aether/AetherCatalog.swift AnyAnime/Aether/AetherStreams.swift AnyAnime/Aether/AetherAdditionalSources.swift AnyAnime/Aether/AetherProvider.swift \
  AnyAnime/Miruro/MiruroProvider.swift Tests/AnimeHomeTests.swift -o "$ANPINIME_HOME_TEST_BINARY"
"$ANPINIME_HOME_TEST_BINARY"
