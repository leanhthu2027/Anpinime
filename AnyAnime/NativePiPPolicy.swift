import Foundation

/// State gates shared by the native bridge and controller. These describe app
/// readiness; only AVKit can report whether a system PiP window starts.
enum NativePiPPolicy {
    /// Allow one bounded wait for AVKit per Home visit; this does not request PiP.
    static func canAwaitAutomaticStart(preference: Bool, supported: Bool, playing: Bool,
                                         decoderReady: Bool, sourceAttached: Bool, attempted: Bool) -> Bool {
        preference && supported && playing && decoderReady && sourceAttached && !attempted
    }
    /// A paused decoded picture can enter PiP after an explicit user gesture.
    /// Automatic entry still requires actual playback; preloading, EOF and a
    /// detached source never qualify for either kind of frame acquisition.
    static func canBootstrapFrame(playing: Bool, manualRequest: Bool,
                                  decoderReady: Bool, sourceAttached: Bool) -> Bool {
        decoderReady && sourceAttached && (manualRequest || playing)
    }

    static func shouldDeferTeardown(active: Bool, pending: Bool, explicitEnd: Bool = false) -> Bool {
        !explicitEnd && (active || pending)
    }
    static func acceptsLifecycleCallback(stopped: Bool, sourceMatchesController: Bool) -> Bool {
        !stopped && sourceMatchesController
    }

    /// Preserve playback intent while the decoder changes output for Home.
    /// Buffering is not a user pause, but EOF and explicit pause still disarm PiP.
    static func automaticPlayback(playing: Bool, transitionIntent: Bool,
                                  userPaused: Bool, decoderReady: Bool) -> Bool {
        decoderReady && !userPaused && (playing || transitionIntent)
    }

    static func automaticAllowed(preference: Bool, eligible: Bool, playing: Bool,
                                 frameReady: Bool, outputPrimed: Bool, sourceAttached: Bool,
                                 outputVisible: Bool) -> Bool {
        preference && eligible && playing && frameReady && outputPrimed && sourceAttached && outputVisible
    }

    /// After AVKit's automatic-entry grace period, pause only if the app still
    /// owns background playback without an active or opening PiP window.
    static func shouldPauseAfterAutomaticTransition(isBackground: Bool, active: Bool, pending: Bool) -> Bool {
        isBackground && !active && !pending
    }

    /// Render into the visible viewport's aspect ratio so mpv can apply fit or
    /// panscan itself. Preserve the fitted video's resolution: the canvas may
    /// need extra space for black bars beyond the source's longest edge.
    /// Keep software-buffer dimensions aligned to four pixels.
    static func inlineOutputSize(source: CGSize, viewport: CGSize, displayScale: CGFloat) -> CGSize {
        func valid(_ size: CGSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        }
        func aligned(_ size: CGSize) -> CGSize {
            CGSize(width: max(4, floor(size.width / 4) * 4),
                   height: max(4, floor(size.height / 4) * 4))
        }
        guard valid(source) else { return CGSize(width: 4, height: 4) }
        guard valid(viewport), displayScale.isFinite, displayScale > 0 else { return aligned(source) }
        let fittedSourceScale = max(source.width / viewport.width, source.height / viewport.height)
        let scale = min(max(1, displayScale), fittedSourceScale)
        return aligned(CGSize(width: viewport.width * scale, height: viewport.height * scale))
    }

    static func shouldStopOnForeground(returnedFromBackground: Bool, transitioningOrActive: Bool) -> Bool {
        returnedFromBackground || transitioningOrActive
    }

    static func acceptsControls(stopped: Bool, stopping: Bool,
                                sourceMatchesController: Bool, sourceIsActive: Bool) -> Bool {
        !stopped && !stopping && sourceMatchesController && sourceIsActive
    }

    static func canAcknowledgeRestore(ownerAlive: Bool, applicationForeground: Bool,
                                      sceneForeground: Bool, sourceAttached: Bool, layoutReady: Bool) -> Bool {
        ownerAlive && applicationForeground && sceneForeground && sourceAttached && layoutReady
    }
}

/// One Home/background visit owns at most one automatic start. An existing
/// window counts too: closing a window that AVKit (or the user) opened must not
/// cause the cleanup callback to reopen it while the app remains backgrounded.
struct NativePiPBackgroundSession {
    private(set) var attempted = false

    mutating func enteredBackground(ownedPictureInPicture: Bool) {
        attempted = attempted || ownedPictureInPicture
    }

    mutating func requestedStart() { attempted = true }
    mutating func enteredForeground() { attempted = false }
}

/// One AVKit restore request owns one completion. Consume it before invoking
/// external code, which can synchronously request restoration again.
struct NativePiPRestoreHandshake {
    private(set) var pendingID: UInt64?
    private var sequence: UInt64 = 0

    mutating func begin() -> UInt64 {
        sequence &+= 1
        pendingID = sequence
        return sequence
    }

    mutating func consume(_ requestID: UInt64) -> Bool {
        guard pendingID == requestID else { return false }
        pendingID = nil
        return true
    }
}

/// The render queue must keep ownership until the main queue has consumed the
/// buffer. A serial render queue alone cannot bound queued main-thread work.
final class NativePiPFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        pending = false
    }
}

/// A missing decoder frame may recover later in the same playback session.
/// Limit each unsuccessful burst, then retry after a cooldown; never exhaust a
/// lifetime attempt counter. The caller owns request IDs and asynchronous reply
/// timeouts, and completes expired requests before submitting a replacement.
struct NativePiPSnapshotRetry {
    private(set) var pending = false
    private(set) var frameReady = false
    private(set) var attemptsInBurst = 0
    private(set) var nextAttemptAt: TimeInterval = 0
    private(set) var totalAttempts = 0

    mutating func beginAttempt(now: TimeInterval, eligible: Bool) -> Bool {
        guard eligible, !pending, !frameReady, now >= nextAttemptAt else { return false }
        pending = true
        attemptsInBurst += 1
        totalAttempts += 1
        return true
    }

    mutating func completeAttempt(frameReady: Bool, now: TimeInterval) {
        guard pending else { return }
        pending = false
        self.frameReady = frameReady
        if frameReady { return }
        if attemptsInBurst >= 3 {
            attemptsInBurst = 0
            nextAttemptAt = now + 2
        }
    }
}
