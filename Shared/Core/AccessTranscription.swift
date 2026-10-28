import CloudKit
import DictationLibrary
import Foundation
import SpeechKit

nonisolated extension AccessGrant {
    func speechAccess() throws -> SpeechProviderAccess {
        .router(try LLMRouter(origin: origin, key: token))
    }
}

nonisolated enum AccessTranscriptionError: Error, Equatable {
    case recordingTooLong
    case notEnoughAllowance
    case unsupportedAudio
}

nonisolated enum TranscriptionRecovery: Equatable {
    case resendArchived
    case refused(AccessFailure)
    case keepForRetry
    case canceled

    init(after error: any Error) {
        switch error {
        case is CancellationError:
            self = .canceled
        case is RealtimeDictationNotStarted:
            self = .resendArchived
        case let failure as AccessFailure:
            self = .refused(failure)
        case RealtimeDictationError.connectionFailed(let underlying):
            self = (underlying as? AccessFailure).map(Self.refused) ?? (underlying is CancellationError ? .canceled : .resendArchived)
        case RealtimeDictationError.streamFailed(let underlying):
            self = Self.isUndispatched(underlying) ? .resendArchived : .keepForRetry
        default:
            self = Self.isUndispatched(error) ? .resendArchived : .keepForRetry
        }
    }

    static func isUndispatched(_ error: any Error) -> Bool {
        guard case SpeechKitError.httpFailure(let statusCode, _) = error else { return false }
        return statusCode == 401 || statusCode == 503
    }
}

actor GrantedRealtimeTranscriptionSession: RealtimeTranscriptionSession {
    nonisolated let sampleRate = AccessGrant.sampleRate
    nonisolated var finalizationTimeout: Duration { .seconds(60) }

    private let grant: Task<AccessGrant, any Error>
    private let request: ProgressiveTranscriptionRequest
    private let onAudioLimitReached: @Sendable () -> Void
    private var upload: ProgressiveRealtimeTranscriptionSession?
    private var budget = AudioSampleBudget(samples: 0)
    private var reportedLimit = false
    private var isDisconnected = false

    init(grant: Task<AccessGrant, any Error>, request: ProgressiveTranscriptionRequest, onAudioLimitReached: @escaping @Sendable () -> Void) {
        self.grant = grant
        self.request = request
        self.onAudioLimitReached = onAudioLimitReached
    }

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, any Error> {
        let grant = try await grant.value
        guard !isDisconnected else { throw CancellationError() }
        let provider = AzureSpeechTranscriptionProvider(configuration: try .init(
            access: try grant.speechAccess(),
            modelOptions: .init(transcribeStyle: .clean)
        ))
        guard provider.progressiveSampleRate == sampleRate else {
            throw SpeechKitError.invalidConfiguration("Progressive sample rate differs from the access grant")
        }
        let upload = ProgressiveRealtimeTranscriptionSession(provider: provider, request: request)
        self.upload = upload
        budget = AudioSampleBudget(samples: grant.audioLimitSamples)
        return try await upload.connectTranscription()
    }

    func sendAudioChunk(_ audioData: Data) async throws {
        guard let upload, !isDisconnected else { throw CancellationError() }
        let chunk = budget.admit(audioData)
        if !chunk.isEmpty { try await upload.sendAudioChunk(chunk) }
        if budget.isSpent { reportLimit() }
    }

    func requestCommit() async throws {
        guard let upload, !isDisconnected else { throw CancellationError() }
        try await upload.requestCommit()
    }

    func disconnect() async {
        isDisconnected = true
        grant.cancel()
        let upload = upload
        self.upload = nil
        await upload?.disconnect()
    }

    private func reportLimit() {
        guard !reportedLimit else { return }
        reportedLimit = true
        onAudioLimitReached()
    }
}

nonisolated struct AudioSampleBudget: Equatable {
    private(set) var remainingBytes: Int

    init(samples: Int) {
        remainingBytes = max(0, samples) * MemoryLayout<Int16>.size
    }

    var isSpent: Bool { remainingBytes == 0 }

    mutating func admit(_ audio: Data) -> Data {
        let chunk = Data(audio.prefix(remainingBytes))
        remainingBytes -= chunk.count
        return chunk
    }
}

@MainActor
struct AccessTranscriber {
    static let maximumAttempts = 3

    let access: MumlaAccess

    func transcribe(wav: Data, languageHints: [String], customVocabulary: [String]) async throws -> TranscriptionResult {
        guard let samples = PCM16WAVHeader.sampleCount(of: wav, sampleRate: AccessGrant.sampleRate), samples > 0 else {
            throw AccessTranscriptionError.unsupportedAudio
        }
        let seconds = (samples + AccessGrant.sampleRate - 1) / AccessGrant.sampleRate
        guard seconds <= AccessGrant.maximumAudioSeconds else { throw AccessTranscriptionError.recordingTooLong }
        var attempt = 1
        while true {
            let grant = try await access.grant(maximumAudioSeconds: seconds)
            guard grant.audioLimitSamples >= samples else { throw AccessTranscriptionError.notEnoughAllowance }
            let engine = try TranscriptionEngineFactory.makeBatchEngine(access: grant.speechAccess())
            let audio = try TranscriptionUploadAudio.wav(data: wav, fileName: "dictation.wav", engine: engine)
            do {
                return try await engine.transcribe(TranscriptionRequest(audio: audio, languageHints: languageHints, customVocabulary: customVocabulary))
            } catch where attempt < Self.maximumAttempts && TranscriptionRecovery.isUndispatched(error) {
                attempt += 1
            }
        }
    }
}

nonisolated enum PCM16WAVHeader {
    static func sampleCount(of data: Data, sampleRate: Int) -> Int? {
        guard data.count >= 44 else { return nil }
        let bytes = [UInt8](data.prefix(44))
        func uint32(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24 }
        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        guard bytes[0..<4] == Array("RIFF".utf8)[...], bytes[8..<12] == Array("WAVE".utf8)[...],
              bytes[12..<16] == Array("fmt ".utf8)[...], uint32(16) == 16, uint16(20) == 1, uint16(22) == 1,
              uint32(24) == sampleRate, uint16(34) == 16, bytes[36..<40] == Array("data".utf8)[...] else { return nil }
        let dataBytes = uint32(40)
        guard dataBytes.isMultiple(of: 2), dataBytes == data.count - 44 else { return nil }
        return dataBytes / 2
    }
}

enum TranscriptionFailureMessage {
    static func text(for error: any Error, allowance: MumlaAccess.State) -> String {
        switch error {
        case let failure as AccessFailure:
            return text(for: failure, allowance: allowance)
        case RealtimeDictationError.connectionFailed(let failure as AccessFailure):
            return text(for: failure, allowance: allowance)
        case let error as DictationLibraryError:
            return error.localizedDescription
        case AccessTranscriptionError.recordingTooLong:
            let limit = Duration.seconds(AccessGrant.maximumAudioSeconds).formatted(.units(allowed: [.minutes], width: .wide))
            return String(localized: "Recordings longer than \(limit) can't be transcribed.")
        case AccessTranscriptionError.notEnoughAllowance:
            return String(localized: "Not enough minutes left for this recording.")
        case let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code):
            return String(localized: "No internet connection.")
        default:
            return String(localized: "Couldn't transcribe. The recording is saved; try again later.")
        }
    }

    private static func text(for failure: AccessFailure, allowance: MumlaAccess.State) -> String {
        switch failure {
        case .allowanceExhausted:
            if case .available(let allowance) = allowance {
                return String(localized: "No minutes left. They reset \(allowance.resetsAt.formatted(.dateTime.month(.wide).day())).")
            }
            return String(localized: "No minutes left this month.")
        case .allowanceBusy:
            return String(localized: "Minutes are in use on another device. Try again in a moment.")
        case .iCloudUnavailable(.noAccount):
            return String(localized: "Sign in to iCloud to dictate.")
        case .iCloudUnavailable:
            return String(localized: "iCloud isn't available right now.")
        case .serviceUnavailable:
            return String(localized: "Can't reach Mumla. Try again in a moment.")
        }
    }
}
