# AnPinime 2.9.4 — IPA build 28

- Source: `f9de91f455847e7fe5666511146d55f1017d947a`
- Branch: `feature/aether-source-coverage`
- One authorized light build: https://github.com/pythonltn2000/Anpinime/actions/runs/43375911349
- IPA artifact: https://github.com/pythonltn2000/Anpinime/actions/runs/43375911349/artifacts/14013859164
- Artifact expiry: 16 November 2026, 13:05 ICT (Asia/Bangkok).
- SHA-256: `9bd37b2d1da51cab4b59bc751b8c9ce5332543065f1992f44d1decfabe884dfe`
- IPA size: 30,917,912 bytes. Unsigned, for signing in ESign.

The downloaded IPA was independently checked against its manifest and the exact
source application tree. Bundle ID is `com.xemphim.aipinime`, version is 2.9.4,
build is 28, libmpv and background audio are included. The bundled metadata
configuration matches the private supplied file; its value was not printed or
committed. No new build was retried or dispatched after this successful run.

Changes and source-by-source evidence: [nine-source repair](AETHER_NINE_SOURCES.md).
Local checks passed: 28 source-specific checks, 128 stream checks and the full
regression suite. The Apple SDK compilation and packaging also passed.

Still requires an iPhone: selecting sources, Fast subservers, recovery after a
failed segment, audio/subtitle/quality controls, resume/seek and automatic Home
PiP. Fast and Shore returned upstream failures in live workspace checks; build
success does not establish that those services are available. No physical-device
playback or automatic PiP success is claimed by this build.
