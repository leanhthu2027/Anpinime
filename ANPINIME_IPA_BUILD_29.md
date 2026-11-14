# AnPinime 2.9.4 — IPA build 29

- Repository: `leanhthu2027/Anpinime`
- Source branch: `feature/automatic-pip-home`
- Application source: `359f04b3b0ce2bf15e1d48b0380ef400aa56b6ca`
- Successful light build: https://github.com/leanhthu2027/Anpinime/actions/runs/43609706595
- Download: https://github.com/leanhthu2027/Anpinime/actions/runs/43609706595/artifacts/14120140573
- Artifact expiry: 17 November 2026, 22:25 ICT (Asia/Bangkok).
- IPA: unsigned, 30,922,998 bytes, for signing with ESign.
- SHA-256: `c9819ecec8c800851b8a44f4d37a3a2174177f0c01b0cbceaa156446892c994f`

The downloaded package was checked against the exact application source tree,
manifest and checksum. Version2.9.4/build29, bundle ID `com.xemphim.aipinime`,
libmpv and background audio are included. Private metadata configuration matches
the supplied file; no credential value was printed or committed.

The new repository now contains the full application history and PiP changes.
PR1 registered the two existing manual-only workflows on main. Application code
remains on the feature branch. One macOS build ran on the new repository; no
additional build or full playback workflow was dispatched.

PiP changes, local checks and iPhone acceptance steps: [Automatic Home PiP](AUTOMATIC_PIP_HOME.md).
Compilation/packaging passed. Physical iPhone automatic PiP, rendering performance,
Home/return cycles and controls still require device verification. Enable both the
app's automatic PiP option and iOS Settings > General > Picture in Picture > Start
PiP Automatically when testing. Build success is not proof of device PiP behavior.
