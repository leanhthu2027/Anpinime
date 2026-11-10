# Local validation

Use the existing checkout, normally `/workspace/Anpinime`. The offline workflow
requires Swift (verified with 6.0.3 in Swift 5 mode), Python 3, Node and jsdom
26.1.0. Keep test dependencies outside the checkout:

```bash
cd /workspace/Anpinime
ANPINIME_JS_TOOLS=$(mktemp -d)
npm install --prefix "$ANPINIME_JS_TOOLS" jsdom@26.1.0 --no-audit --no-fund
NODE_PATH="$ANPINIME_JS_TOOLS/node_modules" bash Tests/local-regressions.sh
```

`ANPINIME_SWIFTC` and `ANPINIME_NODE` can select executable wrappers when tools
are supplied by the environment. Give Swift a writable module cache if needed.
Tests use mocks and loopback HTTP; preserve the inherited proxy and CA settings
and keep loopback in the existing `NO_PROXY`/`no_proxy` configuration.

With FFmpeg installed, run the retained real media-file fixtures as well:

```bash
python3 Tests/relay_fixture_test.py
bash Tests/ai-cache-smoke.sh
```

The HLS test owns port 8765 and verifies its fixture PID before requests. The AI
cache harness uses a dynamic port and verifies its unique identity. Generated
files remain in existing ignored paths. Neither check proves iOS rendering.

On this Linux instance Swift was supplied by the official
`swift:6.0.3-jammy@sha256:95f6ef898992dc840b35517e780f6f6db9661432775ab0b33cc0a531ea749bdb`
container with `--network none`, a bind mount of `/workspace`, and the ordinary
user's UID/GID. No Xcode/Apple SDK substitutes or patched application sources
were used. Home tests retain their existing shims for unrelated WebKit/movie
components; provider, parser and Aether tests compile the production Foundation
logic. Apple UI/Combine tests still need macOS.

Read `AETHER_PIP_MIGRATION_REPORT.md` and `Tools/build-cost-policy.md` before any
iOS build. The workflows remain manual; dispatching macOS/IPA work requires an
explicit user request. Keep live Aether findings separate from the synthetic
fixtures and P-Stream references.
