import CloudKit
import DictationLibrary
import Foundation
import SpeechKit

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
        guard case AccessStreamFailure.refused(let status, _) = error else { return false }
        return status == 401 || status == 503
    }
}

nonisolated enum AccessStreamFailure: Error, Equatable, StructuredDiagnosticError {
    case refused(status: Int, dictationID: String? = nil)
    case invalidReply

    var diagnosticCode: Int? {
        guard case .refused(let status, _) = self else { return nil }
        return status
    }

    var diagnosticReference: String? {
        guard case .refused(_, let dictationID) = self else { return nil }
        return dictationID
    }

    var diagnosticKind: String {
        switch self {
        case .refused: "refused"
        case .invalidReply: "invalid_reply"
        }
    }
}

nonisolated struct AccessStreamReply: Equatable, Sendable {
    let text: String
    let dictationID: String?
    let phrases: [VoicePhrase]?
}

nonisolated enum AccessSpeakers: String, Encodable, Sendable {
    case onRequest
    case diarize
}

nonisolated final class AccessStream: Sendable {
    static let vocabularyBudgetBytes = 128 * 1024
    private static let transport = AccessClient.makeTransport()

    private let socket: URLSessionWebSocketTask
    private let reply: Task<AccessStreamReply, any Error>

    private init(socket: URLSessionWebSocketTask) {
        self.socket = socket
        reply = Task { try await Self.awaitReply(on: socket) }
    }

    static func open(_ grant: AccessGrant, languages: [String], vocabulary: [String], speakers: AccessSpeakers?) async throws -> AccessStream {
        var components = URLComponents(url: grant.origin.appending(path: "/v1/dictations/stream"), resolvingAgainstBaseURL: false)
        components?.scheme = grant.origin.scheme == "http" ? "ws" : "wss"
        guard let url = components?.url else { throw AccessFailure.serviceUnavailable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
        request.setValue(AccessClient.platform, forHTTPHeaderField: AccessClient.platformHeader)
        let socket = transport.webSocketTask(with: request)
        socket.delegate = RejectRedirects.shared
        socket.resume()
        let stream = AccessStream(socket: socket)
        do {
            let start = try JSONEncoder().encode(Start(languages: languages, vocabulary: leadingTerms(of: vocabulary), speakers: speakers))
            try await stream.deliver(.string(String(decoding: start, as: UTF8.self)))
        } catch {
            stream.cancel()
            throw error
        }
        return stream
    }

    static func leadingTerms(of vocabulary: [String]) -> [String] {
        let encoder = JSONEncoder()
        var remaining = vocabularyBudgetBytes - 1
        return Array(vocabulary.prefix { term in
            remaining -= ((try? encoder.encode(term).count) ?? remaining) + 1
            return remaining >= 0
        })
    }

    func send(_ audio: Data) async throws {
        try await deliver(.data(audio))
    }

    func finish() async throws {
        try await deliver(.string(#"{"type":"finish"}"#))
    }

    func requestVoices() async throws {
        try await deliver(.string(#"{"type":"voices"}"#))
    }

    var voices: AccessStreamReply? {
        get async throws {
            _ = try await result
            return try await withTaskCancellationHandler {
                switch try await Self.receiveReply(on: socket) {
                case .unavailable: nil
                case .reply(let reply) where reply.phrases != nil: reply
                case .reply: throw AccessStreamFailure.invalidReply
                }
            } onCancel: { cancel() }
        }
    }

    var result: AccessStreamReply {
        get async throws {
            try await withTaskCancellationHandler { try await reply.value } onCancel: { cancel() }
        }
    }

    func cancel() {
        reply.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private func deliver(_ message: URLSessionWebSocketTask.Message) async throws {
        do {
            try await withTaskCancellationHandler { try await socket.send(message) } onCancel: { cancel() }
        } catch {
            try Task.checkCancellation()
            if case .failure(let reported) = await reply.result { throw reported }
            throw Self.failure(error, on: socket)
        }
    }

    private static func awaitReply(on socket: URLSessionWebSocketTask) async throws -> AccessStreamReply {
        guard case .reply(let reply) = try await receiveReply(on: socket) else { throw AccessStreamFailure.invalidReply }
        return reply
    }

    enum Received: Equatable {
        case reply(AccessStreamReply)
        case unavailable
    }

    private static func receiveReply(on socket: URLSessionWebSocketTask) async throws -> Received {
        let message: URLSessionWebSocketTask.Message
        do { message = try await socket.receive() } catch { throw failure(error, on: socket) }
        guard case .string(let text) = message else { throw AccessStreamFailure.invalidReply }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> Received {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else { throw AccessStreamFailure.invalidReply }
        switch (reply.type, reply.text, reply.status) {
        case ("result", let text?, _): return .reply(AccessStreamReply(text: text, dictationID: reply.id, phrases: nil))
        case ("voices", let text?, _) where reply.phrases != nil:
            return .reply(AccessStreamReply(text: text, dictationID: reply.id, phrases: reply.phrases))
        case ("voices_unavailable", _, _): return .unavailable
        case ("error", _, let status?): throw AccessStreamFailure.refused(status: status, dictationID: reply.id)
        default: throw AccessStreamFailure.invalidReply
        }
    }

    private static func failure(_ error: any Error, on socket: URLSessionWebSocketTask) -> any Error {
        guard let response = socket.response as? HTTPURLResponse, response.statusCode != 101 else { return error }
        return AccessStreamFailure.refused(status: response.statusCode)
    }

    private struct Start: Encodable {
        let type = "start"
        let languages: [String]
        let vocabulary: [String]
        let speakers: AccessSpeakers?
    }

    private struct Reply: Decodable {
        let type: String
        let text: String?
        let status: Int?
        let id: String?
        let phrases: [VoicePhrase]?
    }
}

actor GrantedRealtimeTranscriptionSession: RealtimeTranscriptionSession {
    nonisolated let sampleRate = AccessGrant.sampleRate
    nonisolated var finalizationTimeout: Duration { .seconds(60) }

    private let grant: Task<AccessGrant, any Error>
    private let languageHints: [String]
    private let customVocabulary: [String]
    private let onAudioLimitReached: @Sendable () -> Void
    private let voice: OnlyMyVoice?
    private let watch: VoiceWatch?
    private var stream: AccessStream?
    private var continuation: AsyncThrowingStream<RealtimeTranscriptionEvent, any Error>.Continuation?
    private var outcome: Task<Void, Never>?
    private var voiceCheck: VoiceCheck = .idle
    private var budget = AudioSampleBudget(samples: 0)
    private var reportedLimit = false
    private var isDisconnected = false
    private var isDelivered = false
    private(set) var timing = DictationTiming(captureStartedAt: .now)
    private(set) var voices: VoiceFilterOutcome?

    private enum VoiceCheck {
        case idle
        case checking(Task<Void, Never>)
        case requested(VoiceRecording)
        case notHeard
        case failed(any Error)
    }

    init(grant: Task<AccessGrant, any Error>, languageHints: [String], customVocabulary: [String], voice: OnlyMyVoice?,
         onAudioLimitReached: @escaping @Sendable () -> Void) {
        self.grant = grant
        self.languageHints = languageHints
        self.customVocabulary = customVocabulary
        self.voice = voice
        self.onAudioLimitReached = onAudioLimitReached
        watch = voice.map { VoiceWatch(modelURL: $0.modelURL) }
    }

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, any Error> {
        let grant = try await grant.value
        guard !isDisconnected else { throw CancellationError() }
        let stream = try await AccessStream.open(grant, languages: languageHints, vocabulary: customVocabulary, speakers: voice?.speakers)
        guard !isDisconnected, !Task.isCancelled else {
            stream.cancel()
            throw CancellationError()
        }
        self.stream = stream
        timing.streamOpenedAt = .now
        budget = AudioSampleBudget(samples: grant.audioLimitSamples)
        let events = AsyncThrowingStream<RealtimeTranscriptionEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        continuation = events.continuation
        outcome = Task { [weak self] in
            do {
                let reply = try await stream.result
                await self?.complete(reply)
            } catch {
                await self?.fail(error)
            }
        }
        return events.stream
    }

    func sendAudioChunk(_ audioData: Data) async throws {
        guard let stream, !isDisconnected else { throw CancellationError() }
        let chunk = budget.admit(audioData)
        if !chunk.isEmpty {
            watch?.append(chunk)
            try await stream.send(chunk)
        }
        if budget.isSpent { reportLimit() }
    }

    func requestCommit() async throws {
        guard let stream, !isDisconnected else { throw CancellationError() }
        try await stream.finish()
        timing.finishSentAt = .now
        watch?.finish()
        guard let watch, voice?.speakers == .onRequest, !isDelivered else { return }
        voiceCheck = .checking(Task { [weak self] in
            do {
                let recording = try await watch.recording
                try Task.checkCancellation()
                if recording.isComplete, recording.otherVoiceHeard {
                    try await stream.requestVoices()
                    await self?.decide(.requested(recording))
                } else {
                    await self?.decide(.notHeard)
                }
            } catch {
                await self?.decide(.failed(error))
            }
        })
    }

    func disconnect() async {
        isDisconnected = true
        grant.cancel()
        outcome?.cancel()
        outcome = nil
        if case .checking(let task) = voiceCheck { task.cancel() }
        if !isDelivered { watch?.cancel() }
        continuation?.finish()
        continuation = nil
        stream?.cancel()
        stream = nil
    }

    private func decide(_ check: VoiceCheck) {
        guard case .checking = voiceCheck else { return }
        voiceCheck = check
    }

    private func complete(_ reply: AccessStreamReply) async {
        guard !isDisconnected, let stream else { return }
        timing.resultReceivedAt = .now
        timing.serviceDictationID = reply.dictationID
        var text = reply.text
        switch voiceCheck {
        case .idle:
            voices = voice?.speakers == nil ? nil : .undecided
        case .checking(let task):
            task.cancel()
            voiceCheck = .notHeard
            voices = .undecided
        case .notHeard:
            voices = .notHeard
        case .failed(let error):
            fail(voiceFilter: error)
        case .requested(let recording):
            do {
                guard let profile = voice?.profile.trustedMean else { throw VoiceFilterError.profileNotReady }
                let filtered = try await Self.filter(stream, everyone: reply.text, audio: recording.audio, profile: profile)
                text = filtered.text
                voices = filtered.outcome
            } catch {
                fail(voiceFilter: error)
            }
        }
        guard !isDisconnected else { return }
        isDelivered = true
        continuation?.yield(.committedTranscript(text))
        continuation?.yield(.finalizationCompleted)
        learn()
    }

    nonisolated private static func filter(_ stream: AccessStream, everyone: String, audio: SpeakerAudio, profile: SpeakerEmbedding)
        async throws -> (text: String, outcome: VoiceFilterOutcome)
    {
        try await withThrowingTaskGroup(of: (text: String, outcome: VoiceFilterOutcome).self) { group in
            group.addTask {
                guard let voices = try await stream.voices else { throw VoiceFilterError.voicesUnavailable }
                return try await VoiceFilter.apply(voices, everyone: everyone, audio: audio, profile: profile)
            }
            group.addTask {
                try await Task.sleep(for: VoiceFilter.deadline(forSamples: audio.pcm.sampleCount))
                throw VoiceFilterError.deadlineExceeded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func fail(voiceFilter error: any Error) {
        voices = .failed
        voice?.onFailure(.filter, DiagnosticError(error))
    }

    private func learn() {
        guard let watch, let voice else { return }
        if case .failed = voiceCheck { return }
        Task {
            do {
                guard let candidate = try await watch.recording.learningCandidate() else { return }
                try await voice.store.learn(candidate, startedAt: voice.startedAt)
            } catch is CancellationError {
            } catch {
                voice.onFailure(.learning, DiagnosticError(error))
            }
        }
    }

    private func fail(_ error: any Error) {
        guard !isDisconnected else { return }
        if case AccessStreamFailure.refused(_, let dictationID?) = error {
            timing.resultReceivedAt = .now
            timing.serviceDictationID = dictationID
        }
        continuation?.finish(throwing: error)
    }

    private func reportLimit() {
        guard !reportedLimit else { return }
        reportedLimit = true
        onAudioLimitReached()
    }
}

nonisolated enum VoiceFilterError: Error, Equatable, StructuredDiagnosticError {
    case profileNotReady
    case voicesUnavailable
    case deadlineExceeded
    case modelMissing

    var diagnosticCode: Int? { nil }

    var diagnosticKind: String {
        switch self {
        case .profileNotReady: "profile_not_ready"
        case .voicesUnavailable: "voices_unavailable"
        case .deadlineExceeded: "deadline_exceeded"
        case .modelMissing: "model_missing"
        }
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

nonisolated struct AccessTranscript: Sendable {
    let text: String
    let voices: VoiceFilterOutcome?
}

@MainActor
struct AccessTranscriber {
    static let maximumAttempts = 3
    nonisolated private static let chunkBytes = AccessGrant.sampleRate * MemoryLayout<Int16>.size
    private static let serviceMargin: Duration = .seconds(90)

    let access: MumlaAccess
    let voice: @MainActor () async -> OnlyMyVoice?

    func transcribe(wav: Data, languageHints: [String], customVocabulary: [String]) async throws -> AccessTranscript {
        guard let samples = PCM16WAVHeader.sampleCount(of: wav, sampleRate: AccessGrant.sampleRate), samples > 0 else {
            throw AccessTranscriptionError.unsupportedAudio
        }
        let seconds = (samples + AccessGrant.sampleRate - 1) / AccessGrant.sampleRate
        guard seconds <= AccessGrant.maximumAudioSeconds else { throw AccessTranscriptionError.recordingTooLong }
        let pcm = wav.dropFirst(PCM16WAVHeader.byteCount)
        let voice = samples <= VoiceWatch.maximumSamples ? await self.voice() : nil
        let profile = voice?.profile.trustedMean
        defer { access.refreshInBackground() }
        var attempt = 1
        while true {
            let grant = try await access.grant(maximumAudioSeconds: seconds)
            guard grant.audioLimitSamples >= samples else { throw AccessTranscriptionError.notEnoughAllowance }
            do {
                let reply = try await Self.upload(pcm, grant: grant, languages: languageHints, vocabulary: customVocabulary,
                                                  speakers: profile == nil ? nil : .diarize, deadline: .seconds(seconds) + Self.serviceMargin)
                guard let voice, let profile else { return AccessTranscript(text: reply.text, voices: nil) }
                return await Self.filter(reply, pcm: pcm, voice: voice, profile: profile)
            } catch where attempt < Self.maximumAttempts && TranscriptionRecovery.isUndispatched(error) {
                attempt += 1
            }
        }
    }

    @concurrent nonisolated private static func filter(_ reply: AccessStreamReply, pcm: Data, voice: OnlyMyVoice, profile: SpeakerEmbedding) async -> AccessTranscript {
        do {
            let audio = SpeakerAudio(embedder: try SpeakerEmbedder(modelURL: voice.modelURL), pcm: PCM16Audio(pcm))
            let everyone = reply.phrases.map(VoiceFilter.text(of:)).flatMap { $0.isEmpty ? nil : $0 } ?? reply.text
            let filtered = try await VoiceFilter.apply(reply, everyone: everyone, audio: audio, profile: profile)
            return AccessTranscript(text: filtered.text, voices: filtered.outcome)
        } catch {
            voice.onFailure(.filter, DiagnosticError(error))
            return AccessTranscript(text: reply.text, voices: .failed)
        }
    }

    nonisolated private static func upload(
        _ pcm: Data, grant: AccessGrant, languages: [String], vocabulary: [String], speakers: AccessSpeakers?, deadline: Duration
    ) async throws -> AccessStreamReply {
        try await withThrowingTaskGroup(of: AccessStreamReply.self) { group in
            group.addTask {
                let stream = try await AccessStream.open(grant, languages: languages, vocabulary: vocabulary, speakers: speakers)
                defer { stream.cancel() }
                for offset in stride(from: pcm.startIndex, to: pcm.endIndex, by: chunkBytes) {
                    try await stream.send(Data(pcm[offset..<min(offset + chunkBytes, pcm.endIndex)]))
                }
                try await stream.finish()
                return try await stream.result
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

nonisolated enum PCM16WAVHeader {
    static let byteCount = 44

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
            return String(localized: "Mumla is already dictating on two of your devices. Try again when one finishes.")
        case .iCloudUnavailable(.noAccount):
            return String(localized: "Sign in to iCloud to dictate.")
        case .iCloudUnavailable:
            return String(localized: "iCloud isn't available right now.")
        case .serviceUnavailable:
            return String(localized: "Can't reach Mumla. Try again in a moment.")
        }
    }
}
