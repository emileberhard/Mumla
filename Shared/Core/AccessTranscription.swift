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
        guard case AccessStreamFailure.refused(let status) = error else { return false }
        return status == 401 || status == 503
    }
}

nonisolated enum AccessStreamFailure: Error, Equatable, StructuredDiagnosticError {
    case refused(status: Int)
    case invalidReply

    var diagnosticCode: Int? {
        guard case .refused(let status) = self else { return nil }
        return status
    }

    var diagnosticKind: String {
        switch self {
        case .refused: "refused"
        case .invalidReply: "invalid_reply"
        }
    }
}

nonisolated final class AccessStream: Sendable {
    private static let transport = AccessClient.makeTransport()

    private let socket: URLSessionWebSocketTask
    private let reply: Task<String, any Error>

    private init(socket: URLSessionWebSocketTask) {
        self.socket = socket
        reply = Task { try await Self.awaitReply(on: socket) }
    }

    static func open(_ grant: AccessGrant, languages: [String], vocabulary: [String]) async throws -> AccessStream {
        var components = URLComponents(url: grant.origin.appending(path: "/v1/dictations/stream"), resolvingAgainstBaseURL: false)
        components?.scheme = grant.origin.scheme == "http" ? "ws" : "wss"
        guard let url = components?.url else { throw AccessFailure.serviceUnavailable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
        let socket = transport.webSocketTask(with: request)
        socket.delegate = RejectRedirects.shared
        socket.resume()
        let stream = AccessStream(socket: socket)
        do {
            let start = try JSONEncoder().encode(Start(languages: languages, vocabulary: vocabulary))
            try await stream.deliver(.string(String(decoding: start, as: UTF8.self)))
        } catch {
            stream.cancel()
            throw error
        }
        return stream
    }

    func send(_ audio: Data) async throws {
        try await deliver(.data(audio))
    }

    func finish() async throws {
        try await deliver(.string(#"{"type":"finish"}"#))
    }

    var result: String {
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

    private static func awaitReply(on socket: URLSessionWebSocketTask) async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do { message = try await socket.receive() } catch { throw failure(error, on: socket) }
        guard case .string(let text) = message, let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else {
            throw AccessStreamFailure.invalidReply
        }
        switch (reply.type, reply.text, reply.status) {
        case ("result", let text?, _): return text
        case ("error", _, let status?): throw AccessStreamFailure.refused(status: status)
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
    }

    private struct Reply: Decodable {
        let type: String
        let text: String?
        let status: Int?
    }
}

actor GrantedRealtimeTranscriptionSession: RealtimeTranscriptionSession {
    nonisolated let sampleRate = AccessGrant.sampleRate
    nonisolated var finalizationTimeout: Duration { .seconds(60) }

    private let grant: Task<AccessGrant, any Error>
    private let languageHints: [String]
    private let customVocabulary: [String]
    private let onAudioLimitReached: @Sendable () -> Void
    private var stream: AccessStream?
    private var continuation: AsyncThrowingStream<RealtimeTranscriptionEvent, any Error>.Continuation?
    private var outcome: Task<Void, Never>?
    private var budget = AudioSampleBudget(samples: 0)
    private var reportedLimit = false
    private var isDisconnected = false

    init(grant: Task<AccessGrant, any Error>, languageHints: [String], customVocabulary: [String], onAudioLimitReached: @escaping @Sendable () -> Void) {
        self.grant = grant
        self.languageHints = languageHints
        self.customVocabulary = customVocabulary
        self.onAudioLimitReached = onAudioLimitReached
    }

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, any Error> {
        let grant = try await grant.value
        guard !isDisconnected else { throw CancellationError() }
        let stream = try await AccessStream.open(grant, languages: languageHints, vocabulary: customVocabulary)
        guard !isDisconnected, !Task.isCancelled else {
            stream.cancel()
            throw CancellationError()
        }
        self.stream = stream
        budget = AudioSampleBudget(samples: grant.audioLimitSamples)
        let events = AsyncThrowingStream<RealtimeTranscriptionEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        continuation = events.continuation
        outcome = Task { [weak self] in
            do {
                let text = try await stream.result
                await self?.complete(text)
            } catch {
                await self?.fail(error)
            }
        }
        return events.stream
    }

    func sendAudioChunk(_ audioData: Data) async throws {
        guard let stream, !isDisconnected else { throw CancellationError() }
        let chunk = budget.admit(audioData)
        if !chunk.isEmpty { try await stream.send(chunk) }
        if budget.isSpent { reportLimit() }
    }

    func requestCommit() async throws {
        guard let stream, !isDisconnected else { throw CancellationError() }
        try await stream.finish()
    }

    func disconnect() async {
        isDisconnected = true
        grant.cancel()
        outcome?.cancel()
        outcome = nil
        continuation?.finish()
        continuation = nil
        stream?.cancel()
        stream = nil
    }

    private func complete(_ text: String) {
        guard !isDisconnected else { return }
        continuation?.yield(.committedTranscript(text))
        continuation?.yield(.finalizationCompleted)
    }

    private func fail(_ error: any Error) {
        guard !isDisconnected else { return }
        continuation?.finish(throwing: error)
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
    nonisolated private static let chunkBytes = AccessGrant.sampleRate * MemoryLayout<Int16>.size
    private static let serviceMargin: Duration = .seconds(90)

    let access: MumlaAccess

    func transcribe(wav: Data, languageHints: [String], customVocabulary: [String]) async throws -> String {
        guard let samples = PCM16WAVHeader.sampleCount(of: wav, sampleRate: AccessGrant.sampleRate), samples > 0 else {
            throw AccessTranscriptionError.unsupportedAudio
        }
        let seconds = (samples + AccessGrant.sampleRate - 1) / AccessGrant.sampleRate
        guard seconds <= AccessGrant.maximumAudioSeconds else { throw AccessTranscriptionError.recordingTooLong }
        let pcm = wav.dropFirst(PCM16WAVHeader.byteCount)
        var attempt = 1
        while true {
            let grant = try await access.grant(maximumAudioSeconds: seconds)
            guard grant.audioLimitSamples >= samples else { throw AccessTranscriptionError.notEnoughAllowance }
            do {
                return try await Self.upload(pcm, grant: grant, languages: languageHints, vocabulary: customVocabulary,
                                             deadline: .seconds(seconds) + Self.serviceMargin)
            } catch where attempt < Self.maximumAttempts && TranscriptionRecovery.isUndispatched(error) {
                attempt += 1
            }
        }
    }

    nonisolated private static func upload(
        _ pcm: Data, grant: AccessGrant, languages: [String], vocabulary: [String], deadline: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let stream = try await AccessStream.open(grant, languages: languages, vocabulary: vocabulary)
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
