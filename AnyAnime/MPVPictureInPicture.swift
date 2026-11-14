import AVKit
import CoreVideo
import Libmpv

/// PiP needs sample buffers; a CAMetalLayer cannot be used as its content source.
/// The same mpv decoder/audio session supplies the visible inline source for automatic PiP.
/// Render API calls run on their own queue, without locks/waits on the client API thread.
final class MPVSoftwareVideoOutput {
    private let queue = DispatchQueue(label: "AnPinime.PiP.frames", qos: .userInitiated)
    private var context: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private let deliveryGate = NativePiPFrameGate()
    private var dimensions: (Int32, Int32) = (640, 360)
    private var pool: CVPixelBufferPool?
    var frame: ((CVPixelBuffer) -> Void)?

    func prepare(handle: OpaquePointer, size: CGSize, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard configurePool(size: size) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let api = strdup("sw")!
            defer { free(api) }
            var parameters = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            let result = mpv_render_context_create(&context, handle, &parameters)
            DispatchQueue.main.async { completion(result >= 0) }
        }
    }

    func resize(to size: CGSize) {
        queue.async { [self] in _ = configurePool(size: size) }
    }

    /// Keep the previous working pool on resize/allocation failure.
    private func configurePool(size: CGSize) -> Bool {
        let width = Int32(max(4, Int(size.width) / 4 * 4))
        let height = Int32(max(4, Int(size.height) / 4 * 4))
        guard dimensions.0 != width || dimensions.1 != height || pool == nil else { return true }
        var candidate: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: Int(width), kCVPixelBufferHeightKey: Int(height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 64]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &candidate) == kCVReturnSuccess,
              let candidate else { return false }
        // Creating a pool alone allocates no image memory. Prove that its first
        // frame can be allocated before replacing the visible video output.
        var firstBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, candidate, &firstBuffer) == kCVReturnSuccess else { return false }
        dimensions = (width, height)
        pool = candidate
        return true
    }

    func start() {
        queue.async { [self] in
            guard context != nil, timer == nil else { return }
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(3))
            clock.setEventHandler { [weak self] in self?.render() }
            timer = clock; clock.resume()
        }
    }

    private func render() {
        guard deliveryGate.acquire() else { return }
        var delivered = false
        defer { if !delivered { deliveryGate.release() } }
        guard let context, mpv_render_context_update(context) & 1 != 0 else { return }
        var pixelBuffer: CVPixelBuffer?
        guard let pool else { return }
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits,
            &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let pixels = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        var size = [dimensions.0, dimensions.1]
        var stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var block: Int32 = 0
        let format = strdup("bgr0")!
        defer { free(format) }
        let result: Int32 = size.withUnsafeMutableBufferPointer { sizePointer in
            withUnsafeMutablePointer(to: &stride) { stridePointer in
                withUnsafeMutablePointer(to: &block) { blockPointer in
                    var parameters = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizePointer.baseAddress.map(UnsafeMutableRawPointer.init)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return mpv_render_context_render(context, &parameters)
                }
            }
        }
        guard result >= 0 else { return }
        // bgr0 has no alpha; sample buffers use opaque BGRA.
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        for row in 0..<Int(dimensions.1) {
            for column in 0..<Int(dimensions.0) { bytes[row * stride + column * 4 + 3] = 255 }
        }
        let gate = deliveryGate
        DispatchQueue.main.async { [weak self] in
            defer { gate.release() }
            self?.frame?(pixelBuffer)
        }
        delivered = true
    }

    /// Free before destroying mpv. Completion never blocks the main/client thread.
    func stop(completion: @escaping () -> Void) {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            if let context { mpv_render_context_free(context) }; context = nil
            pool = nil
            DispatchQueue.main.async { completion() }
        }
    }
}

@MainActor
final class MPVPictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let layer = AVSampleBufferDisplayLayer()
    private weak var sourceView: UIView?
    private let displayHost = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let output = MPVSoftwareVideoOutput()
    private let playback: PlaybackState
    private var controller: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var bootstrapFrame: CVPixelBuffer?
    private(set) var frameReady = false
    private var wantsAutomatic = false
    private var possibility: NSKeyValueObservation?
    private var wantsStart = false
    private var starting = false
    private var stopping = false
    private var stopped = false
    private var restoreAfterStop = false
    private var firstFrameTimeout: Task<Void, Never>?
    private var startTimeout: Task<Void, Never>?
    private var stopTimeout: Task<Void, Never>?
    private var cleanupComplete = false
    private var publishesPlaybackState = true
    private var stopCompletions: [() -> Void] = []
    private var retainedUntilStopped: MPVPictureInPicture?
    private var outputReady = false
    private var outputActivated = false
    private var liveFrameReady = false
    private var firstLiveFrameDisplayed = false
    private var decodedSize = CGSize.zero
    private var wantsOutput = false
    private var outputPreparationFailed = false
    private var preparing = false
    private var restoreHandshake = NativePiPRestoreHandshake()
    private var pendingRestore: ((Bool) -> Void)?
    private var restoreTimeout: Task<Void, Never>?
    var onSystemStart: (() -> Void)?
    var onRestoreRequested: (() -> Void)?
    var onEvent: ((String) -> Void)?
    var usesInlineOutput: Bool { outputActivated }
    var possible: Bool { controller?.isPictureInPicturePossible == true }
    var transitioningOrActive: Bool { starting || stopping || controller?.isPictureInPictureActive == true }
    var hasDecodedFrame: Bool { bootstrapFrame != nil || frameReady }
    var automaticReady: Bool { meetsAutomaticRequirements && controller?.canStartPictureInPictureAutomaticallyFromInline == true }
    var pendingRestoreRequestID: UInt64? { restoreHandshake.pendingID }
    private var sourceAttached: Bool {
        guard let sourceView, let window = sourceView.window else { return false }
        return displayHost.window === window && layer.superlayer === displayHost.layer &&
            layer.bounds.width > 1 && layer.bounds.height > 1
    }
    private let command: (String, Double) -> Void
    private let restoreVideo: () -> Void
    private let finished: () -> Void
    #if DEBUG
    private(set) var frameCount = 0
    private(set) var visibleFrameCount = 0
    #endif

    init(playback: PlaybackState, sourceView: UIView, command: @escaping (String, Double) -> Void,
         restoreVideo: @escaping () -> Void, finished: @escaping () -> Void) {
        self.playback = playback; self.command = command; self.restoreVideo = restoreVideo; self.finished = finished
        self.sourceView = sourceView
        super.init()
        var clock: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock) == noErr {
            timebase = clock; layer.controlTimebase = clock
        }
        layer.videoGravity = .resizeAspect; layer.backgroundColor = UIColor.black.cgColor; layer.isOpaque = true
        displayHost.backgroundColor = .clear
        displayHost.isUserInteractionEnabled = false
        displayHost.isAccessibilityElement = false
        displayHost.accessibilityElementsHidden = true
        displayHost.layer.addSublayer(layer)
        updateSourceGeometry()
        output.frame = { [weak self] pixelBuffer in self?.enqueue(pixelBuffer) }
    }

    /// Automatic PiP uses the actual visible inline layer, in this player's
    /// scene. Never advertise a window underlay/snapshot as an inline video.
    func updateSourceGeometry() {
        guard !stopped, !transitioningOrActive, !wantsStart, !playback.pictureInPicturePending,
              let sourceView, let window = sourceView.window else { return }
        let rect = sourceView.convert(sourceView.bounds, to: window)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 1, rect.height > 1 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if outputActivated {
            if displayHost.superview !== sourceView { sourceView.addSubview(displayHost) }
            displayHost.frame = sourceView.bounds
        } else {
            if displayHost.superview !== window { window.insertSubview(displayHost, at: 0) }
            displayHost.frame = rect
        }
        layer.frame = displayHost.bounds
        CATransaction.commit()
        if outputActivated { output.resize(to: inlineOutputSize) }
    }

    private var inlineOutputSize: CGSize {
        NativePiPPolicy.inlineOutputSize(source: decodedSize,
            viewport: sourceView?.bounds.size ?? decodedSize,
            displayScale: sourceView?.window?.screen.nativeScale ?? 1)
    }

    private var visibleInlineSource: Bool {
        guard outputActivated, liveFrameReady, let sourceView,
              displayHost.superview === sourceView, !displayHost.isHidden else { return false }
        var ancestor: UIView? = displayHost
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            ancestor = view.superview
        }
        return displayHasImage
    }

    private var displayHasImage: Bool {
        if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
        return layer.status == .rendering
    }

    /// Arm AVKit while the app is still foreground, using a real decoded frame.
    /// Automatic playback also activates continuous inline output while foreground.
    func arm(snapshot: CVPixelBuffer?, automatic: Bool) {
        guard !stopped, !stopping else { return }
        updateSourceGeometry()
        if layer.status == .failed { layer.flush(); frameReady = false }
        if controller == nil {
            let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
            controller = AVPictureInPictureController(contentSource: content)
            controller?.delegate = self
            possibility = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.onEvent?("possibilityChanged")
                    self?.startIfPossible()
                }
            }
        }
        invalidatePlaybackState()
        if !outputActivated, !frameReady {
            if let snapshot { bootstrapFrame = snapshot }
            // Retry an unaccepted sample on the next foreground poll, then stop
            // enqueueing once one decoded foreground sample is ready.
            if let bootstrapFrame { enqueue(bootstrapFrame, rendered: false) }
        }
        setAutomatic(automatic)
    }

    func setAutomatic(_ enabled: Bool) {
        wantsAutomatic = enabled
        updateSourceGeometry()
        updateAutomaticEligibility()
    }

    private func updateAutomaticEligibility() {
        // enqueue() is not evidence that CoreMedia accepted/displayed an image.
        // Keep the recovery watchdog until display readiness is observed; AVKit
        // may reparent the source meanwhile, so do not require inline ancestry here.
        if outputActivated, liveFrameReady, !firstLiveFrameDisplayed, layer.status != .failed, displayHasImage {
            firstLiveFrameDisplayed = true
            firstFrameTimeout?.cancel(); firstFrameTimeout = nil
            command("pipFrameVisible", 1)
        }
        let enabled = meetsAutomaticRequirements
        if enabled, controller?.canStartPictureInPictureAutomaticallyFromInline != true { prepareAudioSession() }
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    private func prepareAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch { onEvent?("audioSessionActivationFailed") }
    }

    private var meetsAutomaticRequirements: Bool {
        NativePiPPolicy.automaticAllowed(
            preference: wantsAutomatic, eligible: controller != nil && !stopping && !stopped,
            playing: wantsAutomatic && !playback.userPaused, frameReady: frameReady && layer.status != .failed,
            outputPrimed: outputReady, sourceAttached: sourceAttached, outputVisible: visibleInlineSource)
    }

    /// Allocate before changing the visible output. Automatic playback activates
    /// this source inline; manual-only playback activates it on the PiP gesture.
    func primeOutput(handle: OpaquePointer, size: CGSize) {
        guard !stopped, !stopping else { return }
        decodedSize = size
        if outputActivated { output.resize(to: inlineOutputSize) }
        if !preparing, !outputReady, !outputPreparationFailed {
            preparing = true
            output.prepare(handle: handle, size: inlineOutputSize) { [weak self] success in
                guard let self, !self.stopped, !self.stopping else { return }
                self.preparing = false
                guard success else {
                    self.outputPreparationFailed = true
                    self.onEvent?("outputUnavailable")
                    if self.wantsOutput { self.fail("Thiết bị chưa khởi tạo được hình ảnh cho PiP.") }
                    return
                }
                self.outputReady = true
                self.updateAutomaticEligibility()
                self.onEvent?("outputPrimed")
                self.activateOutputIfRequested()
            }
        }
    }

    func prepare(handle: OpaquePointer, size: CGSize, start: Bool) {
        guard !stopped, !stopping else { return }
        prepareAudioSession()
        playback.pictureInPicturePending = true
        wantsOutput = true
        // A failed speculative prime may be retried by a real PiP request.
        outputPreparationFailed = false
        primeOutput(handle: handle, size: size)
        activateOutputIfRequested()
        if start { requestStart() }
    }

    /// Run the visible sample source during normal foreground playback, before
    /// any Home gesture. This does not request a PiP window or change pause intent.
    func primeAutomaticFrames(handle: OpaquePointer, size: CGSize) {
        guard !stopped, !stopping else { return }
        wantsOutput = true
        outputPreparationFailed = false
        primeOutput(handle: handle, size: size)
        activateOutputIfRequested()
    }

    private func activateOutputIfRequested() {
        guard wantsOutput, outputReady, !outputActivated, !stopped, !stopping else { return }
        outputActivated = true
        if let sourceView {
            sourceView.addSubview(displayHost)
            displayHost.frame = sourceView.bounds
            layer.frame = displayHost.bounds
        }
        displayHost.isHidden = true
        bootstrapFrame = nil
        command("pipOutput", 1)
        invalidatePlaybackState()
        output.start()
        firstFrameTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, !self.stopped, !self.stopping, !self.firstLiveFrameDisplayed else { return }
            self.onEvent?("outputUnavailable")
            self.fail("Chưa nhận được hình ảnh PiP. Đã khôi phục trình phát; bạn có thể thử nút PiP.")
        }
        onEvent?("outputActivated")
    }

    func requestStart() {
        guard !stopped, !stopping else { return }
        if controller?.isPictureInPictureActive == true {
            playback.pictureInPicturePending = false
            return
        }
        wantsStart = true
        playback.pictureInPicturePending = true
        onEvent?("startRequested")
        startIfPossible()
        scheduleStartTimeout()
    }

    private func scheduleStartTimeout() {
        guard startTimeout == nil else { return }
        startTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, !self.stopped, !self.stopping, !self.playback.pictureInPictureActive else { return }
            self.fail("iOS chưa mở được cửa sổ PiP. Hãy thử nút cửa sổ nổi khi đang xem.")
        }
    }

    private func enqueue(_ buffer: CVPixelBuffer, rendered: Bool = true) {
        guard !stopped, !stopping, rendered || !frameReady else { return }
        if layer.status == .failed { layer.flush(); frameReady = false; updateAutomaticEligibility() }
        guard layer.isReadyForMoreMediaData else { return }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                          formatDescriptionOut: &description) == noErr, let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: timebase.map(CMTimebaseGetTime) ?? CMTime(seconds: playback.currentTime, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        // mpv already paces these decoded frames. Do not schedule them again on
        // the progress clock, especially the single frame from a paused seek.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(values, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        layer.enqueue(sample)
        if rendered, !liveFrameReady {
            liveFrameReady = true
            displayHost.isHidden = false
        }
        updateAutomaticEligibility()
        if !frameReady {
            frameReady = true
            updateAutomaticEligibility()
            onEvent?("firstFrameReady")
        }
        #if DEBUG
        if rendered { frameCount += 1 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        if let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
            var values: [UInt8] = []
            for y in [height / 4, height / 2, 3 * height / 4] {
                for x in [width / 4, width / 2, 3 * width / 4] {
                    for channel in 0..<3 { values.append(bytes[y * stride + x * 4 + channel]) }
                }
            }
            if rendered, Int(values.max() ?? 0) - Int(values.min() ?? 0) > 30 { visibleFrameCount += 1 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        #endif
        startIfPossible()
    }

    private func startIfPossible() {
        guard wantsStart, !starting, !stopping, !stopped,
              frameReady, outputReady, sourceAttached,
              controller?.isPictureInPictureActive != true,
              controller?.isPictureInPicturePossible == true else { return }
        starting = true; controller?.startPictureInPicture()
    }

    func invalidatePlaybackState() {
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: playback.currentTime, preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: playback.userPaused ? 0 : playback.rate)
        }
        controller?.invalidatePlaybackState()
    }

    func stop(restore: Bool, publishState: Bool = true, completion: @escaping () -> Void = {}) {
        // A replacement may reuse PlaybackState before this renderer finishes
        // its asynchronous cleanup. The retired bridge no longer owns that UI.
        publishesPlaybackState = publishesPlaybackState && publishState
        if cleanupComplete { completion(); return }
        stopCompletions.append(completion)
        restoreAfterStop = restoreAfterStop || restore
        if !restore, let requestID = pendingRestoreRequestID { acknowledgeRestore(requestID, success: false) }
        guard !stopped, !stopping else { return }
        stopping = true; wantsStart = false
        // The owning view/controller may disappear before AVKit's asynchronous
        // didStop. Keep its delegate and render context alive until that handshake.
        retainedUntilStopped = self
        startTimeout?.cancel(); startTimeout = nil
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        bootstrapFrame = nil
        possibility = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        if starting || controller?.isPictureInPictureActive == true {
            // AVKit still owns this content source during its closing animation.
            // Removing it here leaves a stale full-screen PiP placeholder behind.
            controller?.stopPictureInPicture()
            stopTimeout = Task { @MainActor [weak self] in
                let requestedAt = Date()
                var retriedAt = requestedAt
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled, let self, !self.stopped else { return }
                    let active = self.controller?.isPictureInPictureActive == true
                    if !active, !self.starting || Date().timeIntervalSince(requestedAt) >= 5 {
                        self.finishStop(); return
                    }
                    if Date().timeIntervalSince(retriedAt) >= 1 {
                        self.controller?.stopPictureInPicture()
                        retriedAt = Date()
                    }
                }
            }
        } else { finishStop() }
    }

    private func finishStop() {
        guard !stopped else { return }
        stopped = true; starting = false
        if let requestID = pendingRestoreRequestID { acknowledgeRestore(requestID, success: false) }
        stopTimeout?.cancel(); stopTimeout = nil
        controller?.delegate = nil; controller = nil
        // A render context freed while libmpv still owns the VO calls kill_video_async.
        // Switch back while the render queue is still serving frames, then free it.
        if restoreAfterStop, outputActivated { restoreVideo() }
        output.frame = nil
        output.stop { [self] in
            layer.flushAndRemoveImage(); layer.removeFromSuperlayer()
            displayHost.removeFromSuperview()
            cleanupComplete = true
            // Publish after renderer/AVKit cleanup, never during representable teardown.
            // The session can now safely rebuild a viewport or release this decoder.
            if publishesPlaybackState {
                playback.pictureInPicturePending = false
                playback.pictureInPictureActive = false
            }
            let callbacks = stopCompletions; stopCompletions = []
            callbacks.forEach { $0() }
            retainedUntilStopped = nil
        }
    }

    private func fail(_ message: String) {
        onEvent?("failed")
        playback.pictureInPictureError = message
        stop(restore: true) { [weak self] in self?.finished() }
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard acceptsLifecycleCallback(pictureInPictureController) else { return }
        starting = true
        if stopping { pictureInPictureController.stopPictureInPicture(); return }
        playback.pictureInPicturePending = true
        scheduleStartTimeout()
        onSystemStart?()
        onEvent?("willStart")
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard acceptsLifecycleCallback(pictureInPictureController) else { return }
        starting = false
        startTimeout?.cancel(); startTimeout = nil
        if stopping { pictureInPictureController.stopPictureInPicture(); return }
        playback.pictureInPictureActive = true; playback.pictureInPicturePending = false; playback.pictureInPictureError = nil
        onEvent?("didStart")
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard acceptsLifecycleCallback(pictureInPictureController) else { return }
        onEvent?("failedToStart(code=\((error as NSError).code))")
        starting = false
        if stopping { finishStop() }
        else { fail("Chưa mở được PiP: " + error.localizedDescription) }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard acceptsLifecycleCallback(pictureInPictureController) else { return }
        starting = false
        onEvent?("didStop")
        if stopping { finishStop() }
        else { stop(restore: true) { [weak self] in self?.finished() } }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard pictureInPictureController === controller, !stopped else { completionHandler(false); return }
        let supersededCompletion = pendingRestore
        restoreTimeout?.cancel(); restoreTimeout = nil
        let requestID = restoreHandshake.begin()
        pendingRestore = completionHandler
        // Publish the replacement before invoking external code. An older
        // completion can synchronously ask AVKit to restore once more.
        supersededCompletion?(false)
        guard pendingRestoreRequestID == requestID else { return }
        restoreTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.acknowledgeRestore(requestID, success: false)
        }
        onEvent?("restoreRequested")
        guard pendingRestoreRequestID == requestID else { return }
        onRestoreRequested?()
    }

    /// UI ownership/layout is acknowledged before didStop. Waiting for GPU
    /// restoration here would deadlock AVKit's stop/restore handshake.
    @discardableResult
    func acknowledgeRestore(_ requestID: UInt64, success: Bool) -> Bool {
        guard restoreHandshake.consume(requestID) else { return false }
        let completion = pendingRestore
        pendingRestore = nil
        restoreTimeout?.cancel(); restoreTimeout = nil
        completion?(success)
        onEvent?(success ? "restoreAcknowledged" : "restoreRejected")
        return true
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        handlePlaybackCommand(playing: playing, sourceMatchesController: pictureInPictureController === controller,
                              sourceIsActive: pictureInPictureController.isPictureInPictureActive)
    }

    private func handlePlaybackCommand(playing: Bool, sourceMatchesController: Bool, sourceIsActive: Bool) {
        // A source stays armed inline before any PiP window exists. A callback
        // during setup/invalidation is not a Play/Pause action from a PiP user.
        // Only a live PiP window owns user controls. Forwarding an inline pause
        // overwrote the app's user intent and disabled automatic PiP eligibility.
        guard acceptsControls(sourceMatchesController: sourceMatchesController, sourceIsActive: sourceIsActive) else {
            onEvent?(playing ? "ignoredInlinePlay" : "ignoredInlinePause")
            return
        }
        command(playing ? "play" : "pause", 0); controller?.invalidatePlaybackState()
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // AVKit requires a finite range to contain the display layer's current
        // time. Streams may advance before their duration becomes available.
        guard playback.duration > 0 else { return CMTimeRange(start: .zero, duration: .positiveInfinity) }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: max(playback.duration, playback.currentTime + 0.1), preferredTimescale: 600))
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { playback.userPaused }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) {
        guard acceptsControls(sourceMatchesController: pictureInPictureController === controller,
                              sourceIsActive: pictureInPictureController.isPictureInPictureActive) else { completion(); return }
        command("seek", min(playback.duration, max(0, playback.currentTime + skipInterval.seconds))); completion()
    }

    private func acceptsControls(sourceMatchesController: Bool, sourceIsActive: Bool) -> Bool {
        NativePiPPolicy.acceptsControls(stopped: stopped, stopping: stopping,
            sourceMatchesController: sourceMatchesController, sourceIsActive: sourceIsActive)
    }

    private func acceptsLifecycleCallback(_ source: AVPictureInPictureController) -> Bool {
        NativePiPPolicy.acceptsLifecycleCallback(stopped: stopped, sourceMatchesController: source === controller)
    }

    #if DEBUG
    var readinessFacts: [String: Any] {
        ["frameReady": frameReady, "outputPrimed": outputReady,
         "outputActivated": outputActivated, "sourceAttached": sourceAttached,
         "visibleInlineSource": visibleInlineSource, "liveFrameReady": liveFrameReady,
         "firstLiveFrameDisplayed": firstLiveFrameDisplayed,
         "sourceWindow": sourceView?.window != nil,
         "layerAttachedToHost": layer.superlayer === displayHost.layer,
         "hostWindow": displayHost.window != nil,
         "hostFrame": String(describing: displayHost.frame),
         "restorePending": pendingRestoreRequestID != nil,
         "sourceFrame": String(describing: layer.frame),
         "layerBounds": String(describing: layer.bounds), "automaticReady": automaticReady,
         "layerFailed": layer.status == .failed, "layerReadyForSample": layer.isReadyForMoreMediaData]
    }

    /// Exercise the production delegate handler even without a system PiP window.
    /// Unsupported devices return nil from AVKit's initializer. Inject the armed
    /// source's inactive state into the same policy; never manufacture an active
    /// AVKit controller or claim that a system PiP window has been tested.
    @discardableResult
    func debugSimulateArmedPlaybackCommand(playing: Bool) -> Bool {
        guard !transitioningOrActive, !stopped, !stopping else { return false }
        if let controller { pictureInPictureController(controller, setPlaying: playing) }
        else { handlePlaybackCommand(playing: playing, sourceMatchesController: true, sourceIsActive: false) }
        return true
    }
    #endif
}
