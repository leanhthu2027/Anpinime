# Automatic PiP when leaving AnPinime

Build target: AnPinime 2.9.4 (29), branch `feature/automatic-pip-home`.
This change is confined to the shared MPV PiP bridge, its lifecycle policy and
regression coverage. Catalogs, source resolution and playback controls are unchanged.

## Diagnosis

Manual PiP could prepare its sample output while the app was foreground. Automatic
PiP advertised readiness for a single snapshot underneath the opaque app window;
the actual visible video still used a CAMetalLayer. The bridge only activated its
live sample output during `willResignActive`, racing AVKit's inline transition.
Transient decoder buffering also cleared eligibility during the output switch.
These are code-level defects, not a claim of observing the OS decision on an iPhone.

## Changes

- With automatic PiP enabled, the existing MPV decoder supplies a visible, live
  AVSampleBufferDisplayLayer during foreground playback. AVKit gets this actual
  inline source before a Home gesture. No second player/decoder or WebView is added.
- Automatic eligibility requires real display readiness and a visible attached
  source. Playback intent survives transient buffering; explicit pause, EOF,
  preloading, disabled preference and detached ownership still disarm eligibility.
- AVKit owns automatic entry. `didEnterBackground` no longer forces a manual PiP
  start. A one-second grace period prevents premature pausing while AVKit starts;
  a late callback resumes only an app-owned background pause. Control Center does
  not request PiP. Foreground/shutdown cancel the wait.
- Software output uses pooled buffers, bounded delivery and up to 60 render polls
  per second. It renders at the viewport/source resolution, instead of enlarging
  the old 640-pixel PiP image into a full-screen picture. MPV still performs video
  decoding, audio, subtitles, aspect/fill and playback controls. VideoToolbox-copy
  retains hardware decoding; pixel conversion/composition use CPU and require
  device performance/battery checks.
- Failed pool allocation or a missing first displayed frame restores GPU playback;
  automatic preparation is not retried in a loop. Manual PiP can explicitly retry.
  Buffers display immediately because MPV already paces them, including paused seeks.
- Existing asynchronous PiP stop/restore ownership remains. Return from a background
  visit restores the renderer and re-arms inline PiP on the next foreground poll.

## Verification

Passed in the Linux workspace: full `Tests/local-regressions.sh`, 122 native PiP
policy checks (including all 128 readiness combinations), and Swift syntax parsing.
The final policy changes and edited Swift/UI tests were compiled/parsed again.
The suite covers source parsers/transports as regression protection, not live iPhone
playback. Updated UI tests require readiness before each Home cycle, system start/
stop callbacks, one decoder, advancing progress, preserved pause intent and no PiP
on a transient inactive event. These UI tests have not run on Apple hardware here.

An IPA build verifies Apple SDK compilation and package identity only. It cannot
prove automatic PiP works on a physical iPhone.

## iPhone acceptance checks

Enable both AnPinime's automatic PiP preference and iOS Settings > General >
Picture in Picture > Start PiP Automatically.

1. Play a movie with subtitles, wait for normal playback, then swipe Home without
   pressing PiP. Video/audio should continue in the system window.
2. Return to the app, check advancing progress, seek, and repeat Home twice.
3. Pause first, then leave: automatic PiP should not start. Manual PiP should still
   work while paused and resume correctly from its controls.
4. Open/close Control Center: no PiP window, no replaced decoder or frozen progress.
5. Check PiP play/pause, skip, close/restore, rotation, aspect/fill and subtitles on
   VIP, Anime and Phim AI. Check sustained playback smoothness, temperature and battery.
6. Disable automatic PiP in AnPinime: foreground GPU playback and manual PiP remain.
   Disable the iOS automatic option separately: the app must not force a PiP window.

References: [Apple automatic inline PiP](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline),
[custom player PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player),
[display readiness](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/isreadyfordisplay).
