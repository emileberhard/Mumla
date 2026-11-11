import AVFoundation
import Foundation
import Network
import os
import SpeechKit
import Testing
import SpeakerRecognition

private enum SpeakerFixtures {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func speech(_ name: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: repository.appending(path: "Evaluations/RealtimeTranscription/fixtures/\(name).wav"))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: format))
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1_024
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        nonisolated(unsafe) let source = input
        nonisolated(unsafe) var supplied = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            defer { supplied = true }
            status.pointee = supplied ? .endOfStream : .haveData
            return supplied ? nil : source
        }
        if let failure { throw failure }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * 32_767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    static let silence = [Float](repeating: 0, count: 16_000)
}

@Suite("Voice wire")
struct VoiceWireTests {
    @Test func repliesCarryPhrasesOrSayVoicesAreUnavailable() throws {
        #expect(try AccessStream.parse(#"{"type":"result","text":"Hej","id":"d1"}"#)
            == .reply(AccessStreamReply(text: "Hej", dictationID: "d1", phrases: nil)))
        #expect(try AccessStream.parse(#"{"type":"voices","text":"A\nB","phrases":[{"speaker":1,"text":"A","words":[[0,300]]}],"id":"d1"}"#)
            == .reply(AccessStreamReply(text: "A\nB", dictationID: "d1", phrases: [SpeakerPhrase(speaker: 1, text: "A", words: [Duration.zero ..< .milliseconds(300)])])))
        #expect(try AccessStream.parse(#"{"type":"voices_unavailable","id":"d1"}"#) == .unavailable)
        #expect(throws: AccessStreamFailure.invalidReply) { try AccessStream.parse(#"{"type":"voices","text":"A"}"#) }
    }
    @Test func wordPairsAreValidatedAndTranslatedAtTheWireBoundary() throws {
        let json = #"{"type":"voices","text":"Sample.","phrases":[{"speaker":2,"text":"Sample.","words":[[100,200],[-1,20],[0,0],[4],[9223372036854775807,2]]}]}"#
        let reply = try AccessStream.parse(json)
        #expect(reply == .reply(AccessStreamReply(text: "Sample.", dictationID: nil,
            phrases: [SpeakerPhrase(speaker: 2, text: "Sample.", words: [.milliseconds(100) ..< .milliseconds(300)])])))
    }

}

@Suite("Voice session")
struct VoiceSessionTests {
    private static let everyone = "Mine. Theirs."

    @Test(.timeLimit(.minutes(1)), arguments: [
        (#"{"type":"voices_unavailable","id":"synthetic"}"#, "voices_unavailable"),
        (#"{"type":"voices","text":"Mine. Theirs.","id":"synthetic"}"#, "invalid_reply"),
        (nil, "deadline_exceeded"),
    ])
    func aVoicesPassThatFailsDeliversEveryoneAndReportsWhy(reply: String?, kind: String) async throws {
        let service = try await ScriptedAccessService(voicesReply: reply)
        defer { service.stop() }
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        let session = try await Self.session(origin: service.origin, failures: failures)
        let events = try await Self.dictateTwoVoices(into: session)
        var delivered: [String] = []
        for try await event in events {
            if case .committedTranscript(let text) = event { delivered.append(text) }
            if case .finalizationCompleted = event { break }
        }
        #expect(delivered == [Self.everyone])
        #expect(await session.voices?.path == .failed)
        #expect(failures.withLock { $0 } == ["filter:\(kind)"])
        await session.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func disconnectingDuringTheVoicesPassDeliversNothingAndReportsNothing() async throws {
        let service = try await ScriptedAccessService(voicesReply: nil)
        defer { service.stop() }
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        let session = try await Self.session(origin: service.origin, failures: failures)
        let events = try await Self.dictateTwoVoices(into: session)
        while await session.timing.resultReceivedAt == nil { try await Task.sleep(for: .milliseconds(10)) }
        await session.disconnect()
        var delivered: [String] = []
        for try await event in events {
            if case .committedTranscript(let text) = event { delivered.append(text) }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(delivered.isEmpty)
        #expect(failures.withLock { $0 }.isEmpty)
    }

    private static func session(origin: URL, failures: OSAllocatedUnfairLock<[String]>) async throws -> GrantedRealtimeTranscriptionSession {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = VoiceProfileStore(accountDirectory: directory)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(await store.profile())) as? [String: Any])
        payload["exemplars"] = (0..<5).map { _ in ["values": [Float(1)] + [Float](repeating: 0, count: 255)] }
        payload["recentMatches"] = [Bool](repeating: true, count: 10)
        let profile = try JSONDecoder().decode(VoiceProfile.self, from: JSONSerialization.data(withJSONObject: payload))
        try #require(profile.isTrusted)
        let voice = OnlyMyVoice(profile: profile, store: store, startedAt: .now) { stage, error in
            failures.withLock { $0.append("\(stage.rawValue):\(error.kind ?? error.typeName)") }
        }
        let grant = AccessGrant(token: "synthetic", audioLimitSamples: 120 * AccessGrant.sampleRate, origin: origin)
        return GrantedRealtimeTranscriptionSession(grant: Task { grant }, languageHints: [], customVocabulary: [], voice: voice,
                                                   onAudioLimitReached: {})
    }

    private static func dictateTwoVoices(into session: GrantedRealtimeTranscriptionSession)
        async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, any Error>
    {
        let events = try await session.connectTranscription()
        var samples: [Float] = []
        for name in ["en-teen-note", "en-landlord-email"] { samples += try SpeakerFixtures.speech(name) + SpeakerFixtures.silence }
        let pcm = SpeakerFixtures.pcm16(samples)
        for offset in stride(from: 0, to: pcm.count, by: 3_200) {
            try await session.sendAudioChunk(pcm.subdata(in: offset..<min(offset + 3_200, pcm.count)))
        }
        try await session.requestCommit()
        return events
    }
}

nonisolated private final class ScriptedAccessService: Sendable {
    let origin: URL
    private let listener: NWListener

    init(voicesReply: String?) async throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "scripted-access-service")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receive(on: connection, voicesReply: voicesReply)
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        origin = try #require(URL(string: "http://localhost:\(port)"))
    }

    func stop() { listener.cancel() }

    private static func receive(on connection: NWConnection, voicesReply: String?) {
        connection.receiveMessage { content, context, _, error in
            guard error == nil else { return connection.cancel() }
            if let content, type(of: content, context: context) == "voices" {
                send(#"{"type":"result","text":"Mine. Theirs.","id":"synthetic"}"#, on: connection)
                if let voicesReply { send(voicesReply, on: connection) }
            }
            receive(on: connection, voicesReply: voicesReply)
        }
    }

    private static func type(of content: Data, context: NWConnection.ContentContext?) -> String? {
        guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
              metadata.opcode == .text,
              let message = try? JSONSerialization.jsonObject(with: content) as? [String: Any] else { return nil }
        return message["type"] as? String
    }

    private static func send(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
}

@Suite("Voice budget")
struct VoiceBudgetTests {
    @Test(arguments: [(0, 4_000), (30, 4_150), (600, 6_000), (1_800, 6_000)])
    func theAddedWaitUsesTheCalibratedMinimumAndCap(seconds: Int, milliseconds: Int) {
        #expect(AccessVoiceCheck.waitBudget(forSamples: seconds * AccessGrant.sampleRate) == .milliseconds(milliseconds))
    }
}
