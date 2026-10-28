import DictationLibrary
import AVFAudio
import Foundation
import os
import Synchronization

enum SessionAudioEngineError: LocalizedError {
    case formatUnavailable
    case fakeMicFileUnreadable(String)
    case hapticsDuringRecordingUnavailable
    case backgroundSessionUnavailable
    case builtInMicrophoneUnavailable
    case builtInMicrophoneRouteUnavailable

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            "Could not configure the microphone audio format."
        case .fakeMicFileUnreadable(let path):
            "Fake mic WAV is not readable: \(path)"
        case .hapticsDuringRecordingUnavailable:
            "Could not keep system haptics enabled while the microphone is active."
        case .backgroundSessionUnavailable:
            "Could not keep the dictation session ready in the background."
        case .builtInMicrophoneUnavailable:
            "The built-in microphone is not available for recording."
        case .builtInMicrophoneRouteUnavailable:
            "The system did not route recording to the built-in microphone."
        }
    }
}

/// Keeps a mixable recording session alive for keyboard-triggered dictation.
/// The keyboard can only toggle capture state; iOS rejects starting input from
/// the containing app after it has already moved to the background.
actor SessionAudioEngine {
    nonisolated static let sampleRate = OriginalAudio.batchProviderSampleRate
    private nonisolated static let recordingCategoryOptions: AVAudioSession.CategoryOptions = [
        .allowBluetoothA2DP,
        .mixWithOthers,
    ]

    private let queue = DispatchSerialQueue(label: "emileberhard.WisprClone.audio-session", qos: .userInitiated)
    private let levelMeter = AudioLevelMeter()
    private let diagnosticsSnapshot = Mutex<AudioSessionDiagnostics?>(nil)
    private var engine: AVAudioEngine?
    private var processor: TapProcessor?
    /// Target PCM16 rate of the installed tap. Realtime providers dictate
    /// their own rate (OpenAI realtime only accepts 24 kHz); batch captures
    /// use the 16 kHz default.
    private var captureSampleRate = SessionAudioEngine.sampleRate
    private var isRunning = false
    private var isCapturing = false
    private var isCaptureSuspended = false
    /// PCM16 captured before an interruption suspended the tap. Prepended to
    /// the live capture so one dictation survives announcement interruptions.
    private var carriedPCM = Data()
    private var originalAudio: OriginalAudioWriter?
    private var captureGeneration = UUID()
    private var capturePCMCallback: (@Sendable (Data) -> Void)?

    #if targetEnvironment(simulator)
    /// E2E test seam: the simulator runtime on this host aborts the whole
    /// process inside AURemoteIO::Initialize when mic input starts, so tests
    /// inject "recorded" audio from a WAV file instead of touching the engine.
    private let fakeMicWAVPath = ProcessInfo.processInfo.environment["MUMLA_FAKE_MIC_WAV"]
    #endif

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Normalized microphone level (0...1) for waveform UI.
    nonisolated var currentLevel: Double {
        levelMeter.level
    }

    nonisolated var diagnostics: [String: String] {
        guard let snapshot = diagnosticsSnapshot.withLock({ $0 }) else {
            return ["audio_session_snapshot": "unavailable"]
        }
        return snapshot.metadata
    }

    func start() throws {
        defer { publishDiagnostics() }
        guard !isRunning else { return }

        #if targetEnvironment(simulator)
        if let fakeMicWAVPath {
            guard FileManager.default.isReadableFile(atPath: fakeMicWAVPath) else {
                throw SessionAudioEngineError.fakeMicFileUnreadable(fakeMicWAVPath)
            }
            isRunning = true
            return
        }
        #endif

        let session = AVAudioSession.sharedInstance()
        engine = AVAudioEngine()
        do {
            try Self.configureRecordingAudioSession(session)
            try session.setActive(true)
            try Self.configurePreferredAudioRoute(on: session)
            try ensureRecordingEngineReady()
        } catch {
            releaseEngine()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        isRunning = true
    }

    func stop() {
        defer { publishDiagnostics() }
        resetCapture()
        guard isRunning else { return }
        isRunning = false
        #if targetEnvironment(simulator)
        if fakeMicWAVPath != nil {
            return
        }
        #endif
        releaseEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func restart() throws {
        stop()
        try start()
    }

    func discardEngineAfterMediaServicesReset() {
        defer { publishDiagnostics() }
        guard isRunning else { return }
        #if targetEnvironment(simulator)
        if fakeMicWAVPath != nil {
            return
        }
        #endif
        if isCapturing, !isCaptureSuspended, let processor {
            carriedPCM.append(processor.endCapture())
            isCaptureSuspended = true
        }
        engine = nil
        processor = nil
        isRunning = false
    }

    /// Parks an in-flight capture across an audio session interruption. The
    /// system already deactivated the session and stopped buffer delivery;
    /// this drains the captured PCM so it survives the tap being rebuilt with
    /// a possibly different input format on resume.
    func suspendCaptureForInterruption() {
        defer { publishDiagnostics() }
        guard isRunning, isCapturing, !isCaptureSuspended else { return }
        #if targetEnvironment(simulator)
        if fakeMicWAVPath != nil {
            isCaptureSuspended = true
            return
        }
        #endif
        if let processor {
            carriedPCM.append(processor.endCapture())
        }
        removeCaptureTap()
        engine?.stop()
        processor = nil
        isCaptureSuspended = true
    }

    /// Reactivates the session and continues the suspended capture. Throws
    /// while the interrupting system audio still holds the session; callers
    /// retry on a probe schedule.
    func resumeCaptureAfterInterruption() throws {
        defer { publishDiagnostics() }
        guard isRunning, isCapturing, isCaptureSuspended else { return }
        #if targetEnvironment(simulator)
        if fakeMicWAVPath != nil {
            isCaptureSuspended = false
            return
        }
        #endif
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)
        try Self.configurePreferredAudioRoute(on: session)
        // A prior resume attempt may have installed the tap and then failed to
        // start the engine; never install twice on the same bus.
        try ensureRecordingEngineReady()
        processor?.beginCapture(onPCM16Data: capturePCMCallback, originalAudio: originalAudio)
        isCaptureSuspended = false
    }

    func beginCapture(
        onPCM16Data: (@Sendable (Data) -> Void)? = nil,
        sampleRate: Int = SessionAudioEngine.sampleRate,
        originalAudio: OriginalAudioWriter
    ) throws {
        defer { publishDiagnostics() }
        #if targetEnvironment(simulator)
        if fakeMicWAVPath != nil {
            return
        }
        #endif
        guard isRunning else {
            throw SessionAudioEngineError.backgroundSessionUnavailable
        }
        guard !isCapturing else { return }

        if sampleRate != captureSampleRate {
            removeCaptureTap()
            engine?.stop()
            processor = nil
            captureSampleRate = sampleRate
        }

        try ensureRecordingEngineReady()
        try Self.configurePreferredAudioRoute(on: AVAudioSession.sharedInstance())

        guard let processor else {
            throw SessionAudioEngineError.backgroundSessionUnavailable
        }
        self.originalAudio?.discard()
        self.originalAudio = originalAudio
        carriedPCM = Data()
        captureGeneration = UUID()
        capturePCMCallback = onPCM16Data
        processor.beginCapture(onPCM16Data: onPCM16Data, originalAudio: originalAudio)
        isCapturing = true
        isCaptureSuspended = false
    }

    /// Returns the provider WAV (PCM16 mono at the capture sample rate) and the
    /// encoded original.
    func endCapture() async -> CapturedDictationAudio {
        defer { publishDiagnostics() }
        return await finishCapture()
    }

    /// Ends realtime capture after CoreAudio has delivered the input buffer
    /// that was already in flight when stop was requested. A quiet buffer ends
    /// the tail immediately; ongoing speech gets a bounded chance to finish.
    func endRealtimeCapture() async -> CapturedDictationAudio {
        defer { publishDiagnostics() }
        #if targetEnvironment(simulator)
        if fakeMicWAVPath != nil {
            return await finishCapture()
        }
        #endif
        guard isCapturing, !isCaptureSuspended, let processor else {
            return await finishCapture()
        }

        let generation = captureGeneration
        let initialSnapshot = processor.realtimeTailSnapshot
        let clock = ContinuousClock()
        let startedAt = clock.now
        while !RealtimeCaptureTailPolicy.shouldFinish(
            initialBufferCount: initialSnapshot.deliveredBufferCount,
            currentSnapshot: processor.realtimeTailSnapshot,
            elapsed: startedAt.duration(to: clock.now)
        ) {
            do {
                try await Task.sleep(for: RealtimeCaptureTailPolicy.pollInterval)
            } catch {
                break
            }
        }

        guard captureGeneration == generation else {
            return CapturedDictationAudio(providerWAV: Data(), original: .failure(OriginalAudioError.empty))
        }
        return await finishCapture()
    }

    func discardCapture() {
        defer { publishDiagnostics() }
        resetCapture()
    }

    func restoreIdleSessionAfterCapture() throws {
        defer { publishDiagnostics() }
        guard isRunning else {
            throw SessionAudioEngineError.backgroundSessionUnavailable
        }
        #if targetEnvironment(simulator)
        if fakeMicWAVPath != nil {
            return
        }
        #endif
        resetCapture()
        do {
            try ensureRecordingEngineReady()
            try Self.configurePreferredAudioRoute(on: AVAudioSession.sharedInstance())
        } catch {
            releaseEngine()
            isRunning = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    var isReadyForCapture: Bool {
        isRunning && Self.inputRouteState(of: AVAudioSession.sharedInstance()).routesBuiltInMicrophone
    }

    func enforcePreferredAudioRoute() throws {
        defer { publishDiagnostics() }
        guard isRunning else { return }
        try Self.configurePreferredAudioRoute(on: AVAudioSession.sharedInstance())
    }

    func handleRouteChange() -> AudioInputRouteState {
        defer { publishDiagnostics() }
        let session = AVAudioSession.sharedInstance()
        if isRunning {
            Self.routeBuiltInReceiverToSpeakerIfNeeded(on: session)
        }
        return Self.inputRouteState(of: session)
    }

    func inputRouteState() -> AudioInputRouteState {
        Self.inputRouteState(of: AVAudioSession.sharedInstance())
    }

    private func finishCapture() async -> CapturedDictationAudio {
        captureGeneration = UUID()
        #if targetEnvironment(simulator)
        if let fakeMicWAVPath {
            let url = URL(fileURLWithPath: fakeMicWAVPath)
            return CapturedDictationAudio(
                providerWAV: (try? Data(contentsOf: url)) ?? Data(),
                original: Result { try OriginalAudioWriter.encode(contentsOf: url) }
            )
        }
        #endif
        isCapturing = false
        isCaptureSuspended = false
        capturePCMCallback = nil
        let pcm = carriedPCM + (processor?.endCapture() ?? Data())
        carriedPCM = Data()
        let originalAudio = originalAudio
        self.originalAudio = nil
        guard !pcm.isEmpty, let originalAudio,
              let providerWAV = try? RealtimePCM16WAVFile.data(pcmData: pcm, sampleRate: captureSampleRate)
        else {
            originalAudio?.discard()
            return CapturedDictationAudio(providerWAV: Data(), original: .failure(OriginalAudioError.empty))
        }
        return CapturedDictationAudio(providerWAV: providerWAV, originalAudio: originalAudio)
    }

    private func resetCapture() {
        captureGeneration = UUID()
        _ = processor?.endCapture()
        isCapturing = false
        isCaptureSuspended = false
        carriedPCM = Data()
        originalAudio?.discard()
        originalAudio = nil
        capturePCMCallback = nil
    }

    private func ensureRecordingEngineReady() throws {
        guard let engine else {
            throw SessionAudioEngineError.backgroundSessionUnavailable
        }
        if processor == nil {
            try installCaptureTap(on: engine)
        }
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func installCaptureTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            inputFormat.sampleRate > 0,
            let targetFormat = OriginalAudio.pcm16Format(sampleRate: captureSampleRate),
            let processor = TapProcessor(
                inputFormat: inputFormat,
                targetFormat: targetFormat,
                levelMeter: levelMeter
            )
        else {
            throw SessionAudioEngineError.formatUnavailable
        }

        // @Sendable so the closure stays nonisolated: it would otherwise
        // inherit this actor's isolation, and the runtime's isolation check
        // traps when CoreAudio calls it on the tap queue.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            processor.ingest(buffer)
        }
        self.processor = processor
    }

    private func removeCaptureTap() {
        guard processor != nil, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func releaseEngine() {
        removeCaptureTap()
        engine?.stop()
        engine = nil
        processor = nil
    }

    private func publishDiagnostics() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let snapshot = AudioSessionDiagnostics(
            values: [
                "audio_available_inputs": AudioPortDiagnostics.describe(session.availableInputs ?? []),
                "audio_capture_running": isCapturing.description,
                "audio_capture_suspended": isCaptureSuspended.description,
                "audio_category": session.category.rawValue,
                "audio_category_options": String(session.categoryOptions.rawValue),
                "audio_engine_running": isRunning.description,
                "audio_input_channels": String(session.inputNumberOfChannels),
                "audio_mode": session.mode.rawValue,
                "audio_output_channels": String(session.outputNumberOfChannels),
                "audio_preferred_input": session.preferredInput.map(AudioPortDiagnostics.describe) ?? "none",
                "audio_route_inputs": AudioPortDiagnostics.describe(route.inputs),
                "audio_route_outputs": AudioPortDiagnostics.describe(route.outputs),
                "audio_sample_rate": String(Int(session.sampleRate.rounded())),
                "haptics_during_recording": session.allowHapticsAndSystemSoundsDuringRecording.description,
                "other_audio_playing": session.isOtherAudioPlaying.description,
            ],
            capturedAt: Date()
        )
        diagnosticsSnapshot.withLock { $0 = snapshot }
    }

    private nonisolated static func configureRecordingAudioSession(_ session: AVAudioSession) throws {
        try session.setCategory(.playAndRecord, mode: .default, options: recordingCategoryOptions)
        // Banner-style incoming calls should ring without killing dictation;
        // iOS only interrupts if the call is answered. Best-effort preference:
        // never worth failing session startup over.
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        guard session.allowHapticsAndSystemSoundsDuringRecording else {
            throw SessionAudioEngineError.hapticsDuringRecordingUnavailable
        }
    }

    private nonisolated static func configurePreferredAudioRoute(on session: AVAudioSession) throws {
        guard
            let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic })
        else {
            throw SessionAudioEngineError.builtInMicrophoneUnavailable
        }

        if session.preferredInput?.portType != .builtInMic {
            try session.setPreferredInput(builtInMic)
        }

        guard inputRouteState(of: session).routesBuiltInMicrophone else {
            throw SessionAudioEngineError.builtInMicrophoneRouteUnavailable
        }

        routeBuiltInReceiverToSpeakerIfNeeded(on: session)
    }

    private nonisolated static func routeBuiltInReceiverToSpeakerIfNeeded(on session: AVAudioSession) {
        let outputs = session.currentRoute.outputs
        guard outputs.count == 1, outputs[0].portType == .builtInReceiver else { return }

        // This is a playback-quality preference, not a dictation invariant.
        // Keep the microphone session usable if iOS declines the route override.
        try? session.overrideOutputAudioPort(.speaker)
    }

    private nonisolated static func inputRouteState(of session: AVAudioSession) -> AudioInputRouteState {
        let routeInputs = session.currentRoute.inputs
        return AudioInputRouteState(
            builtInMicrophoneAvailable: session.availableInputs?.contains { $0.portType == .builtInMic } ?? false,
            routeHasInputs: !routeInputs.isEmpty,
            routesBuiltInMicrophone: routeInputs.contains { $0.portType == .builtInMic }
        )
    }
}

nonisolated enum AudioPortDiagnostics {
    static func describe(_ ports: [AVAudioSessionPortDescription]) -> String {
        guard !ports.isEmpty else { return "none" }
        return ports.map(describe).joined(separator: "|")
    }

    static func describe(_ port: AVAudioSessionPortDescription) -> String {
        "\(port.portType.rawValue):\(port.portName)"
    }
}

private nonisolated struct AudioSessionDiagnostics: Sendable {
    let values: [String: String]
    let capturedAt: Date

    var metadata: [String: String] {
        values.merging(
            ["audio_session_snapshot_age_ms": String(Int(Date().timeIntervalSince(capturedAt) * 1_000))]
        ) { _, new in new }
    }
}

private nonisolated final class AudioLevelMeter: Sendable {
    private let storage = Mutex(0.0)

    var level: Double {
        storage.withLock { $0 }
    }

    func update(_ level: Double) {
        storage.withLock { $0 = level }
    }
}

/// Converts incoming microphone buffers to PCM16 mono on the audio tap thread.
private nonisolated final class TapProcessor: Sendable {
    private struct State {
        let converter: StreamingAudioConverter
        var capturing = false
        var pcm = Data()
        var level: Double = 0
        var deliveredBufferCount = 0
        var onPCM16Data: (@Sendable (Data) -> Void)?
        var originalAudio: OriginalAudioWriter?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let levelMeter: AudioLevelMeter

    init?(inputFormat: AVAudioFormat, targetFormat: AVAudioFormat, levelMeter: AudioLevelMeter) {
        let converter = StreamingAudioConverter(outputFormat: targetFormat)
        guard converter.supports(inputFormat) else {
            return nil
        }
        self.state = OSAllocatedUnfairLock(uncheckedState: State(converter: converter))
        self.levelMeter = levelMeter
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // CoreAudio owns this non-Sendable buffer, but the tap and lock body
        // consume it synchronously before ingest returns.
        nonisolated(unsafe) let inputBuffer = buffer
        state.withLockUnchecked { state in
            // Serialize conversion with endCapture() so a buffer already being
            // processed when the user taps stop reaches the original, the
            // recovery WAV, and the realtime sender before capture closes.
            guard state.capturing else { return }

            state.originalAudio?.write(inputBuffer)
            guard let converted = state.converter.convert(inputBuffer),
                  let channel = converted.int16ChannelData
            else { return }

            let frames = Int(converted.frameLength)
            let data = Data(bytes: channel[0], count: frames * MemoryLayout<Int16>.size)
            state.level = Self.normalizedRMS(channel[0], frames: frames)
            levelMeter.update(state.level)
            state.deliveredBufferCount += 1
            state.pcm.append(data)
            state.onPCM16Data?(data)
        }
    }

    func beginCapture(onPCM16Data: (@Sendable (Data) -> Void)?, originalAudio: OriginalAudioWriter?) {
        state.withLockUnchecked { state in
            state.capturing = true
            state.pcm = Data()
            state.level = 0
            state.deliveredBufferCount = 0
            state.onPCM16Data = onPCM16Data
            state.originalAudio = originalAudio
            levelMeter.update(0)
        }
    }

    func endCapture() -> Data {
        state.withLockUnchecked { state in
            let pcm = state.pcm
            state.capturing = false
            state.pcm = Data()
            state.level = 0
            state.onPCM16Data = nil
            state.originalAudio = nil
            levelMeter.update(0)
            return pcm
        }
    }

    var realtimeTailSnapshot: RealtimeCaptureTailSnapshot {
        state.withLockUnchecked { state in
            RealtimeCaptureTailSnapshot(
                deliveredBufferCount: state.deliveredBufferCount,
                level: state.level
            )
        }
    }

    private static func normalizedRMS(_ samples: UnsafePointer<Int16>, frames: Int) -> Double {
        guard frames > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<frames {
            let sample = Double(samples[index]) / Double(Int16.max)
            sum += sample * sample
        }
        return min(1, sqrt(sum / Double(frames)) * 4)
    }
}
