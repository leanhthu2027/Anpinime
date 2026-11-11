import Foundation

/// Linux/macOS: swiftc AnyAnime/NativePiPPolicy.swift Tests/NativePiPPolicyTests.swift -o /tmp/native-pip-policy-tests
@main
struct NativePiPPolicyTests {
    private static var checks = 0

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }
        checks += 1
        print("PASS: " + message)
    }

    static func main() {
        verifyReadiness()
        verifyPausedManualEntry()
        require(NativePiPPolicy.canAttemptAutomaticStart(preference: true, supported: true, playing: true,
            decoderReady: true, sourceAttached: true, attempted: false),
            "Home transition may acquire the first PiP frame when speculative snapshot priming was unavailable")
        require(!NativePiPPolicy.canAttemptAutomaticStart(preference: true, supported: true, playing: true,
            decoderReady: true, sourceAttached: true, attempted: true),
            "a failed automatic request cannot restart endlessly from its cleanup callback")
        require(!NativePiPPolicy.canAttemptAutomaticStart(preference: true, supported: true, playing: false,
            decoderReady: true, sourceAttached: true, attempted: false),
            "Home transition respects a paused video")
        require(!NativePiPPolicy.canAttemptAutomaticStart(preference: false, supported: true, playing: true,
            decoderReady: true, sourceAttached: true, attempted: false),
            "disabled automatic PiP remains disabled even with a ready decoder")
        verifyRetryRecovery()
        verifyInterruptedRequest()
        verifyForegroundAndControls()
        verifyRestoreReadiness()
        verifyRestoreHandshake()
        verifyFrameGateDelivery()
        verifyConcurrentFrameGate()
        verifyLateLifecycleCallbacks()
        print("\(checks) native PiP policy checks passed")
    }

    private static func verifyPausedManualEntry() {
        // With bit order playing/manual/decoder/attached, only these three
        // complete ready states may acquire a frame. This also covers preload,
        // missing dimensions/EOF and detachment represented by decoder/owner gates.
        let allowedStates: Set<Int> = [13, 14, 15]
        for bits in 0..<16 {
            let playing = bits & 1 != 0, manual = bits & 2 != 0
            let decoderReady = bits & 4 != 0, attached = bits & 8 != 0
            require(NativePiPPolicy.canBootstrapFrame(playing: playing, manualRequest: manual,
                decoderReady: decoderReady, sourceAttached: attached) == allowedStates.contains(bits),
                "bootstrap acquisition keeps ownership and decoder gates across manual/playing states: \(bits)")
        }
        let pausedManual = NativePiPPolicy.canBootstrapFrame(playing: false, manualRequest: true,
            decoderReady: true, sourceAttached: true)
        var retry = NativePiPSnapshotRetry()
        require(retry.beginAttempt(now: 0, eligible: pausedManual), "a paused decoded movie can request its first PiP snapshot after a manual gesture")
        retry.completeAttempt(frameReady: true, now: 0)
        require(retry.frameReady, "the paused snapshot completes normal bootstrap readiness without resuming playback")
        require(!NativePiPPolicy.automaticAllowed(preference: true, eligible: true, playing: false,
            frameReady: retry.frameReady, outputPrimed: true, sourceAttached: true),
            "manual readiness never enables automatic PiP for a paused movie")
    }

    private static func verifyLateLifecycleCallbacks() {
        for bits in 0..<4 {
            require(!NativePiPPolicy.shouldDeferTeardown(active: bits & 1 != 0, pending: bits & 2 != 0, explicitEnd: true),
                "explicit source/library/player replacement always releases old playback: \(bits)")
        }
        for bits in 0..<4 {
            require(NativePiPPolicy.shouldDeferTeardown(active: bits & 1 != 0, pending: bits & 2 != 0) == (bits != 0),
                    "representable teardown waits for active/pending owner: \(bits)")
        }
        for stopped in [false, true] {
            for matches in [false, true] {
                require(NativePiPPolicy.acceptsLifecycleCallback(stopped: stopped, sourceMatchesController: matches) == (!stopped && matches),
                        "lifecycle ownership rejects stale controller/teardown: stopped=\(stopped), matches=\(matches)")
            }
        }
        // Reproduce the old path: a delayed didStart from a released controller
        // used to write active=true into the shared playback of its replacement.
        var active = false
        if NativePiPPolicy.acceptsLifecycleCallback(stopped: true, sourceMatchesController: false) { active = true }
        require(!active, "late didStart cannot resurrect a torn-down PiP session")
        active = true
        if NativePiPPolicy.acceptsLifecycleCallback(stopped: false, sourceMatchesController: false) { active = false }
        require(active, "an old didStop cannot clear the current controller's active state")
    }

    private static func verifyReadiness() {
        // Exercise every combination so that a missing single gate cannot allow
        // auto entry, including a prepared controller with no enqueued frame.
        var enabledCombinations = 0
        for bits in 0..<64 {
            let enabled = NativePiPPolicy.automaticAllowed(
                preference: bits & 1 != 0, eligible: bits & 2 != 0,
                playing: bits & 4 != 0, frameReady: bits & 8 != 0,
                outputPrimed: bits & 16 != 0, sourceAttached: bits & 32 != 0)
            guard enabled == (bits == 63) else {
                fatalError("FAIL: readiness combination \(bits) bypassed a gate")
            }
            if enabled { enabledCombinations += 1 }
        }
        require(enabledCombinations == 1, "all six actual-readiness gates are required across 64 combinations")
        require(!NativePiPPolicy.automaticAllowed(preference: true, eligible: true, playing: false,
            frameReady: true, outputPrimed: true, sourceAttached: true), "buffering or paused playback disarms automatic entry")
        require(!NativePiPPolicy.automaticAllowed(preference: true, eligible: true, playing: true,
            frameReady: true, outputPrimed: true, sourceAttached: false), "detaching the real source view disarms automatic entry")
    }

    private static func verifyRetryRecovery() {
        var retry = NativePiPSnapshotRetry()
        require(!retry.beginAttempt(now: 0, eligible: false), "ineligible decoder state never submits a screenshot")
        require(retry.totalAttempts == 0, "waiting for valid dimensions does not spend the burst")
        for attempt in 0..<3 {
            let now = Double(attempt) / 4
            require(retry.beginAttempt(now: now, eligible: true), "eligible snapshot attempt \(attempt + 1) is allowed")
            require(!retry.beginAttempt(now: now + 0.1, eligible: true), "only one screenshot command may be pending")
            retry.completeAttempt(frameReady: false, now: now)
        }
        require(!retry.beginAttempt(now: 2.49, eligible: true), "three failed frames require a full two-second cooldown")
        require(retry.beginAttempt(now: 2.5, eligible: true), "a fourth attempt can recover in the same playback session")
        retry.completeAttempt(frameReady: true, now: 2.5)
        require(retry.frameReady && !retry.pending && retry.totalAttempts == 4, "only acknowledged frame readiness completes bootstrap")
        require(!retry.beginAttempt(now: 100, eligible: true), "a ready foreground sample stops further snapshot requests")
    }

    private static func verifyInterruptedRequest() {
        var retry = NativePiPSnapshotRetry()
        require(retry.beginAttempt(now: 10, eligible: true), "a command starts pending")
        // The owner has expired the reply ID before completing a timed-out
        // attempt. The replacement receives a new ID in the controller.
        retry.completeAttempt(frameReady: false, now: 12)
        require(retry.beginAttempt(now: 12, eligible: true), "an expired async command can be replaced")
        retry.completeAttempt(frameReady: false, now: 12)
        retry.completeAttempt(frameReady: true, now: 13)
        require(!retry.frameReady, "unsolicited or duplicate completion cannot invent frame readiness")
        require(retry.beginAttempt(now: 13, eligible: true), "retry remains available after ignored duplicate completion")
        retry.completeAttempt(frameReady: false, now: 13)
        require(!retry.beginAttempt(now: 14, eligible: true), "timeout failures count toward burst throttling")
        require(retry.beginAttempt(now: 15, eligible: true), "timeout recovery resumes after cooldown")
        var newSession = NativePiPSnapshotRetry()
        require(newSession.beginAttempt(now: 0, eligible: true), "a new playback session has independent retry state")
    }

    private static func verifyForegroundAndControls() {
        require(!NativePiPPolicy.shouldStopOnForeground(returnedFromBackground: false, transitioningOrActive: false),
                "Control Center return preserves the armed inline bridge")
        require(NativePiPPolicy.shouldStopOnForeground(returnedFromBackground: true, transitioningOrActive: false),
                "actual background return can release the prior bridge")
        require(NativePiPPolicy.shouldStopOnForeground(returnedFromBackground: false, transitioningOrActive: true),
                "active or pending PiP closes through its asynchronous stop handshake")
        var accepted = 0
        for bits in 0..<16 {
            let allowed = NativePiPPolicy.acceptsControls(stopped: bits & 1 != 0, stopping: bits & 2 != 0,
                sourceMatchesController: bits & 4 != 0, sourceIsActive: bits & 8 != 0)
            guard allowed == (bits == 12) else { fatalError("FAIL: control combination \(bits) bypassed ownership") }
            if allowed { accepted += 1 }
        }
        require(accepted == 1, "only the live current PiP controller accepts controls across 16 combinations")
    }

    private static func verifyRestoreReadiness() {
        var accepted = 0
        for bits in 0..<32 {
            let allowed = NativePiPPolicy.canAcknowledgeRestore(
                ownerAlive: bits & 1 != 0, applicationForeground: bits & 2 != 0,
                sceneForeground: bits & 4 != 0, sourceAttached: bits & 8 != 0,
                layoutReady: bits & 16 != 0)
            guard allowed == (bits == 31) else { fatalError("FAIL: restore readiness combination \(bits) bypassed a gate") }
            if allowed { accepted += 1 }
        }
        require(accepted == 1, "restore success requires owner, foreground app/scene, attached source and layout across 32 combinations")
    }

    private static func verifyRestoreHandshake() {
        var handshake = NativePiPRestoreHandshake()
        require(!handshake.consume(1) && handshake.pendingID == nil, "a restore acknowledgement cannot invent a request")
        let first = handshake.begin()
        let replacement = handshake.begin()
        require(first != replacement && handshake.pendingID == replacement, "replacement restore requests get a new identity")
        require(!handshake.consume(first) && handshake.pendingID == replacement, "an out-of-order acknowledgement preserves the replacement")
        require(handshake.consume(replacement) && handshake.pendingID == nil, "the current restore completion is consumed exactly once")
        require(!handshake.consume(replacement), "a duplicate restore acknowledgement is ignored")

        // The real bridge consumes ownership before invoking AVKit's completion.
        // Simulate a synchronous new request from that external completion.
        let outer = handshake.begin()
        require(handshake.consume(outer), "restore ownership clears before external completion code runs")
        let reentrant = handshake.begin()
        require(!handshake.consume(outer) && handshake.pendingID == reentrant, "an old completion cannot clear a reentrant restore request")
        require(handshake.consume(reentrant), "the reentrant request can finish independently")

        let timedOut = handshake.begin()
        require(handshake.consume(timedOut), "timeout or teardown can consume the current restore request")
        let later = handshake.begin()
        require(!handshake.consume(timedOut) && handshake.pendingID == later, "a late timeout cannot reject a newer restore request")
        require(handshake.consume(later), "restore remains usable after cancellation and timeout")
    }

    private final class FrameOwner { }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private static func verifyFrameGateDelivery() {
        let gate = NativePiPFrameGate()
        let renderQueue = DispatchQueue(label: "PiP.tests.render")
        let deliveryQueue = DispatchQueue(label: "PiP.tests.delivery")
        let submitted = DispatchSemaphore(value: 0)
        let allowDelivery = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let cancelled = LockedCounter()
        var owner: FrameOwner? = FrameOwner()
        require(gate.acquire(), "the first rendered frame owns delivery")
        deliveryQueue.async { [weak owner] in
            defer { gate.release(); finished.signal() }
            submitted.signal()
            allowDelivery.wait()
            if owner == nil { cancelled.increment(); return }
        }
        require(submitted.wait(timeout: .now() + 3) == .success, "the frame reaches the asynchronous consumer queue")
        let contendersFinished = DispatchSemaphore(value: 0)
        let unexpectedAcquisitions = LockedCounter()
        renderQueue.async {
            for _ in 0..<100 { if gate.acquire() { unexpectedAcquisitions.increment(); gate.release() } }
            contendersFinished.signal()
        }
        require(contendersFinished.wait(timeout: .now() + 3) == .success && unexpectedAcquisitions.value == 0,
                "the render queue cannot accumulate frames while consumer delivery is pending")
        owner = nil
        allowDelivery.signal()
        require(finished.wait(timeout: .now() + 3) == .success && cancelled.value == 1,
                "a cancelled or deallocated frame owner still completes consumer cleanup")
        require(gate.acquire(), "consumer cleanup releases the gate after owner cancellation")
        gate.release()

        // Allocation/render failure takes the producer's early-return path.
        func failedRender(allocationSucceeded: Bool) {
            guard gate.acquire() else { fatalError("FAIL: failure path could not acquire delivery") }
            defer { gate.release() }
            guard allocationSucceeded else { return }
        }
        failedRender(allocationSucceeded: false)
        require(gate.acquire(), "an early producer failure does not strand delivery ownership")
        gate.release()
    }

    private static func verifyConcurrentFrameGate() {
        let gate = NativePiPFrameGate()
        for round in 1...2 {
            let winners = LockedCounter()
            DispatchQueue.concurrentPerform(iterations: 128) { _ in
                if gate.acquire() { winners.increment() }
            }
            require(winners.value == 1, "only one of 128 concurrent frame submissions wins delivery in round \(round)")
            gate.release()
        }
    }
}
