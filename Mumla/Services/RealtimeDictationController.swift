@preconcurrency import AVFoundation
import CoreAudio
import DictationLibrary
import Foundation
import OSLog
import SpeechKit

@MainActor
final class RealtimeDictationController {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mumla", category: "RealtimeDictation")
    let diagnosticsSessionID = UUID().uuidString

    private let makeOriginalAudio: @MainActor () async throws -> OriginalAudioWriter
    private let makeProviderConfiguration: @MainActor (OriginalAudioWriter) throws -> RealtimeDictationProviderConfiguration
    private var providerConfiguration: RealtimeDictationProviderConfiguration?
    private var microphoneCapture: BuiltInMicrophoneCapture?
    private var originalAudio: OriginalAudioWriter?
    private var finishedOriginalAudio: Result<URL, any Error>?
    private var dictation: RealtimeDictation?
    private var isRunning = false
    private var isTerminating = false
    private var startedAt: Date?

    init(makeProviderConfiguration: @escaping @MainActor (OriginalAudioWriter) throws -> RealtimeDictationProviderConfiguration, makeOriginalAudio: @escaping @MainActor () async throws -> OriginalAudioWriter) {
        self.makeOriginalAudio = makeOriginalAudio
        self.makeProviderConfiguration = makeProviderConfiguration
    }

    func start() async throws {
        guard !isRunning else { return }
        let originalAudio = try await makeOriginalAudio()
        self.originalAudio = originalAudio
        do {
            try Task.checkCancellation()
            let configuration = try makeProviderConfiguration(originalAudio)
            providerConfiguration = configuration
            let dictation = RealtimeDictation(session: configuration.makeSession())
            self.dictation = dictation
            isRunning = true
            isTerminating = false
            startedAt = Date()
            AppDiagnostics.info("Starting realtime recording", category: "realtime", metadata: baseDiagnosticsMetadata)

            try Task.checkCancellation()
            try await startMicrophoneCapture(dictation: dictation, initialOriginal: originalAudio)
        } catch {
            isTerminating = true
            await cleanup()
            throw error
        }
    }

    func stop() async -> RealtimeDictationResult {
        guard isRunning else {
            return RealtimeDictationResult(
                diagnosticsSessionID: diagnosticsSessionID,
                text: nil,
                originalAudio: await finishOriginalAudio(),
                fallbackReason: "realtime_not_started",
                failure: RealtimeDictationNotStarted()
            )
        }

        isTerminating = true
        prepareAudioForArchiving()
        async let original = finishOriginalAudio()
        guard let dictation else {
            let originalAudio = await original
            await cleanup()
            return RealtimeDictationResult(
                diagnosticsSessionID: diagnosticsSessionID,
                text: nil,
                originalAudio: originalAudio,
                fallbackReason: "realtime_not_started",
                failure: RealtimeDictationNotStarted()
            )
        }
        let completion = await RealtimeDictationCompletion.finish(dictation)
        if completion.error != nil {
            AppDiagnostics.warning(
                "Realtime transcription failed; using saved audio",
                category: "realtime",
                metadata: baseDiagnosticsMetadata.merging([
                    "fallback_reason": completion.fallbackReason ?? "unknown",
                    "recording_elapsed_ms": startedAt.map { String(Self.elapsedMilliseconds(since: $0)) } ?? "unknown",
                ]) { _, new in new }
            )
        }

        if completion.error == nil {
            AppDiagnostics.info(
                "Realtime recording stopped",
                category: "realtime",
                metadata: baseDiagnosticsMetadata.merging([
                    "fallback_reason": completion.fallbackReason ?? "none",
                    "final_text_length": String(completion.text?.count ?? 0),
                ]) { _, new in new }
            )
        }
        let originalAudio = await original
        await cleanup()
        return RealtimeDictationResult(
            diagnosticsSessionID: diagnosticsSessionID,
            text: completion.text,
            originalAudio: originalAudio,
            fallbackReason: completion.fallbackReason,
            failure: completion.error
        )
    }

    func prepareAudioForArchiving() {
        stopAudioCapture()
    }

    func cancelAndRecoverAudio() async -> Result<URL, any Error>? {
        isTerminating = true
        prepareAudioForArchiving()
        let originalAudio = await finishOriginalAudio()
        await cleanup()
        return originalAudio
    }

    func cancel() async {
        guard isRunning else { return }
        isTerminating = true
        stopAudioCapture()
        await cleanup()
    }

    private func finishOriginalAudio() async -> Result<URL, any Error>? {
        if let finishedOriginalAudio { return finishedOriginalAudio }
        prepareAudioForArchiving()
        guard let originalAudio else { return nil }
        let result = await Self.finish(originalAudio)
        finishedOriginalAudio = result
        return result
    }

    @concurrent
    private static func finish(_ originalAudio: OriginalAudioWriter) async -> Result<URL, any Error> {
        do { return .success(try await originalAudio.finishArchived()) }
        catch { return .failure(error) }
    }

    private var baseDiagnosticsMetadata: [String: String] {
        (providerConfiguration?.diagnosticsMetadata ?? [:]).merging([
            "realtime_session_id": diagnosticsSessionID,
            "sample_rate": dictation.map { String($0.sampleRate) } ?? "unknown",
        ]) { _, new in new }
    }

    private static func elapsedMilliseconds(since startDate: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startDate) * 1_000))
    }

    private func startMicrophoneCapture(dictation: RealtimeDictation, initialOriginal: OriginalAudioWriter) async throws {
        var lastStartupError: Error?

        for attempt in 1...MicrophoneCaptureStartup.maxAttemptCount {
            try Task.checkCancellation()
            let originalAudio = attempt == 1 ? initialOriginal : try await makeOriginalAudio()
            try Task.checkCancellation()
            guard originalAudio.dictationPlan == initialOriginal.dictationPlan else {
                originalAudio.discard()
                throw DictationLibraryError.accountChanged
            }
            let capture = try BuiltInMicrophoneCapture(
                providerSampleRate: dictation.sampleRate,
                originalAudio: originalAudio
            ) { [dictation] pcmData in
                AudioAnalyzer.pushExternalRMS(PCM16AudioLevel.rms(from: pcmData))
                dictation.append(pcmData)
            }
            let startupMetadata = capture.metadata
                .merging([
                    "capture_startup_attempt": String(attempt),
                    "capture_startup_timeout_ms": String(MicrophoneCaptureStartup.firstBufferTimeoutMilliseconds),
                ]) { _, new in new }
            AppDiagnostics.info("Configured realtime microphone", category: "audio", metadata: startupMetadata)

            do {
                try await capture.start(timeoutMilliseconds: MicrophoneCaptureStartup.firstBufferTimeoutMilliseconds)
            } catch is CancellationError {
                originalAudio.discard()
                throw CancellationError()
            } catch {
                originalAudio.discard()
                lastStartupError = error
                AppDiagnostics.warning(
                    "Realtime microphone capture startup failed; rebuilding capture session",
                    category: "audio",
                    metadata: startupMetadata
                        .merging(capture.metadata) { _, new in new }
                        .merging(DiagnosticError(error).metadata) { _, new in new }
                )
                continue
            }
            guard !Task.isCancelled, !isTerminating else {
                capture.stop()
                originalAudio.discard()
                throw CancellationError()
            }

            logger.info("Realtime microphone capture started")
            AppDiagnostics.info(
                "Realtime microphone capture started",
                category: "audio",
                metadata: startupMetadata.merging(capture.metadata) { _, new in new }
            )
            microphoneCapture = capture
            self.originalAudio = originalAudio
            return
        }

        throw lastStartupError ?? MicrophoneCaptureStartupError.noInputBuffers(
            timeoutMilliseconds: MicrophoneCaptureStartup.firstBufferTimeoutMilliseconds,
            attempt: MicrophoneCaptureStartup.maxAttemptCount
        )
    }

    private func stopAudioCapture() {
        microphoneCapture?.stop()
        microphoneCapture = nil
        AudioAnalyzer.resetLevel()
    }

    private func cleanup() async {
        stopAudioCapture()
        await dictation?.cancel()
        dictation = nil
        originalAudio?.discard()
        originalAudio = nil
        isRunning = false
        isTerminating = false
        startedAt = nil
    }
}

private enum PreferredInputMicrophone {
    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &deviceID) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                $0
            )
        }

        guard status == noErr else {
            throw PreferredInputMicrophoneError.unableToReadSystemDefaultInputDevice(status)
        }

        return deviceID
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, $0)
        }

        return status == noErr ? value : 0
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String {
        stringProperty(
            for: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? "unknown"
    }

    private static func stringProperty(
        for deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedString: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedString) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr, let unmanagedString else { return nil }
        return unmanagedString as String
    }

    static func systemDefaultInputMetadata() -> [String: String] {
        guard let deviceID = try? defaultInputDeviceID() else {
            return [
                "system_default_input_device_id": "unknown",
                "system_default_input_device_name": "unknown",
                "system_default_input_device_transport": "unknown",
            ]
        }

        return [
            "system_default_input_device_id": String(deviceID),
            "system_default_input_device_name": deviceName(for: deviceID),
            "system_default_input_device_transport": transportDescription(for: deviceID),
        ]
    }

    private static func transportDescription(for deviceID: AudioDeviceID) -> String {
        switch transportType(for: deviceID) {
        case kAudioDeviceTransportTypeBuiltIn:
            "built_in"
        case kAudioDeviceTransportTypeVirtual:
            "virtual"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            "bluetooth"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            "continuity_capture"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            "display"
        case kAudioDeviceTransportTypeUSB:
            "usb"
        default:
            "0x" + String(transportType(for: deviceID), radix: 16)
        }
    }
}

enum PreferredInputMicrophoneError: LocalizedError {
    case builtInMicrophoneUnavailable
    case unableToReadSystemDefaultInputDevice(OSStatus)

    var errorDescription: String? {
        switch self {
        case .builtInMicrophoneUnavailable:
            return "No built-in microphone was available for dictation."
        case .unableToReadSystemDefaultInputDevice(let status):
            return "Failed to read the system default audio input device (\(status))."
        }
    }
}

enum MicrophoneCaptureStartup {
    static let maxAttemptCount = 2
    static let firstBufferTimeoutMilliseconds = 1_000
}

enum MicrophoneCaptureStartupError: LocalizedError {
    case invalidSampleRate(Int)
    case captureSessionDidNotStart
    case noInputBuffers(timeoutMilliseconds: Int, attempt: Int)
    case unableToAddCaptureInput(String)
    case unableToAddCaptureOutput

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let sampleRate):
            "Invalid microphone capture sample rate \(sampleRate)."
        case .captureSessionDidNotStart:
            "The built-in microphone capture session did not start."
        case .noInputBuffers(let timeoutMilliseconds, let attempt):
            if attempt > 0 {
                "The selected microphone produced no audio buffers within \(timeoutMilliseconds) ms after capture startup (attempt \(attempt))."
            } else {
                "The selected microphone produced no audio buffers within \(timeoutMilliseconds) ms after capture startup."
            }
        case .unableToAddCaptureInput(let name):
            "Unable to add \(name) as the capture session input."
        case .unableToAddCaptureOutput:
            "Unable to add audio data output to the capture session."
        }
    }
}

private nonisolated final class MicrophoneCaptureActivityMonitor: Sendable {
    private struct State {
        var bufferCount = 0
        var sampleCount = 0
        var byteCount = 0
    }

    private static let firstBufferPollInterval: Duration = .milliseconds(10)

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func record(sampleCount: Int, byteCount: Int) {
        guard sampleCount > 0, byteCount > 0 else { return }

        lock.withLock { state in
            state.bufferCount += 1
            state.sampleCount += sampleCount
            state.byteCount += byteCount
        }
    }

    func waitForFirstBuffer(timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !hasReceivedBuffer {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: Self.firstBufferPollInterval)
        }
        return true
    }

    var metadata: [String: String] {
        let state = lock.withLock { $0 }
        return [
            "capture_buffer_count": String(state.bufferCount),
            "capture_sample_count": String(state.sampleCount),
            "capture_byte_count": String(state.byteCount),
        ]
    }

    private var hasReceivedBuffer: Bool {
        lock.withLock { $0.bufferCount > 0 }
    }
}

final class BuiltInMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let providerSampleRate: Int
    private let providerConverter: OSAllocatedUnfairLock<StreamingAudioConverter>
    private let originalAudio: OriginalAudioWriter
    private let onPCM16Data: @Sendable (Data) -> Void
    private let captureQueue = DispatchQueue(label: "emileberhard.WisprClone.built-in-microphone-capture")
    private let sessionQueue = DispatchQueue(label: "emileberhard.WisprClone.built-in-microphone-session")
    private let captureActivity = MicrophoneCaptureActivityMonitor()
    private let deliversPCM = OSAllocatedUnfairLock(initialState: true)
    private let device: AVCaptureDevice

    init(
        providerSampleRate: Int,
        originalAudio: OriginalAudioWriter,
        onPCM16Data: @escaping @Sendable (Data) -> Void
    ) throws {
        guard providerSampleRate > 0, let providerFormat = OriginalAudio.pcm16Format(sampleRate: providerSampleRate) else {
            throw MicrophoneCaptureStartupError.invalidSampleRate(providerSampleRate)
        }

        self.providerSampleRate = providerSampleRate
        self.providerConverter = OSAllocatedUnfairLock(uncheckedState: StreamingAudioConverter(outputFormat: providerFormat))
        self.originalAudio = originalAudio
        self.onPCM16Data = onPCM16Data
        self.device = try Self.builtInMicrophone()
        super.init()
        try configureCaptureSession()
    }

    var metadata: [String: String] {
        [
            "selected_capture_device_name": device.localizedName,
            "selected_capture_device_uid": device.uniqueID,
            "selected_capture_device_model": device.modelID,
            "selected_capture_device_transport": Self.transportDescription(for: device.transportType),
            "selected_capture_device_type": device.deviceType.rawValue,
            "selected_capture_device_connected": device.isConnected.description,
            "selected_capture_device_suspended": device.isSuspended.description,
            "selected_capture_device_in_use": device.isInUseByAnotherApplication.description,
            "capture_sample_rate": String(Int(OriginalAudioWriter.format.sampleRate)),
            "capture_channel_count": String(OriginalAudioWriter.format.channelCount),
            "capture_format": "pcm_f32le",
            "provider_sample_rate": String(providerSampleRate),
            "capture_source": "av_capture_session",
            "available_capture_devices": Self.captureDevicesSummary(),
        ].merging(PreferredInputMicrophone.systemDefaultInputMetadata()) { _, new in new }
            .merging(captureActivity.metadata) { _, new in new }
    }

    func start(timeoutMilliseconds: Int) async throws {
        let isRunning = await withCheckedContinuation { continuation in
            sessionQueue.async { [captureSession] in
                captureSession.startRunning()
                continuation.resume(returning: captureSession.isRunning)
            }
        }

        guard isRunning else {
            throw MicrophoneCaptureStartupError.captureSessionDidNotStart
        }

        do {
            guard try await captureActivity.waitForFirstBuffer(timeout: .milliseconds(timeoutMilliseconds)) else {
                throw MicrophoneCaptureStartupError.noInputBuffers(timeoutMilliseconds: timeoutMilliseconds, attempt: 0)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        deliversPCM.withLock { $0 = false }
        captureOutput.setSampleBufferDelegate(nil, queue: nil)
        captureQueue.sync {}
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard deliversPCM.withLock({ $0 }), let buffer = Self.pcmBuffer(from: sampleBuffer) else {
            return
        }
        originalAudio.write(buffer)
        guard let pcmData = providerConverter.withLockUnchecked({ $0.convert(buffer)?.pcm16MonoData }),
              !pcmData.isEmpty else {
            return
        }

        captureActivity.record(
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            byteCount: pcmData.count
        )
        onPCM16Data(pcmData)
    }

    private func configureCaptureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw MicrophoneCaptureStartupError.unableToAddCaptureInput(device.localizedName)
        }
        captureSession.addInput(input)

        captureOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: OriginalAudioWriter.format.sampleRate,
            AVNumberOfChannelsKey: OriginalAudioWriter.format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        captureOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard captureSession.canAddOutput(captureOutput) else {
            throw MicrophoneCaptureStartupError.unableToAddCaptureOutput
        }
        captureSession.addOutput(captureOutput)
    }

    private static func builtInMicrophone() throws -> AVCaptureDevice {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        guard let device = discoverySession.devices.first(where: isBuiltInAudioDevice(_:)) else {
            throw PreferredInputMicrophoneError.builtInMicrophoneUnavailable
        }

        return device
    }

    private nonisolated static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                  frameCapacity: frameCount
              )
        else { return nil }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    private static func isBuiltInAudioDevice(_ device: AVCaptureDevice) -> Bool {
        device.hasMediaType(.audio)
            && UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeBuiltIn
    }

    private static func captureDevicesSummary() -> String {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices
            .map {
                "\($0.localizedName)#\($0.uniqueID){transport=\(transportDescription(for: $0.transportType)),connected=\($0.isConnected),suspended=\($0.isSuspended),in_use=\($0.isInUseByAnotherApplication)}"
            }
            .joined(separator: ";")
    }

    private static func transportDescription(for transportType: Int32) -> String {
        switch UInt32(bitPattern: transportType) {
        case kAudioDeviceTransportTypeBuiltIn:
            "built_in"
        case kAudioDeviceTransportTypeVirtual:
            "virtual"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            "bluetooth"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            "continuity_capture"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            "display"
        case kAudioDeviceTransportTypeUSB:
            "usb"
        default:
            "0x" + String(UInt32(bitPattern: transportType), radix: 16)
        }
    }
}
