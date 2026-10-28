#if DEBUG
import CloudKit
import Foundation
import os
import SpeechKit
import Synchronization

@MainActor
enum AccessProbe {
    private struct Receipt: Encodable {
        var origin = ""
        var stage = ""
        var cloudKitError: Int?
        var health: Health?
        var freshProof: Rejection?
        var enrolledNatively = false
        var replayedProof: Rejection?
        var forgedProof: Rejection?
        var transcribeAgain: Transcription?
        var pacedCompletion: Transcription?
        var pacedCancellation: Cancellation?
        var proofLifetime: ProofLifetime?
        var failure: String?
        var passed = false

        var allPassed: Bool {
            if let proofLifetime { return health?.ready == true && proofLifetime.expired?.rejectedAsIdentity == true }
            return health?.ready == true && enrolledNatively && freshProof?.status == 201
                && replayedProof != nil && forgedProof?.rejectedAsIdentity == true
                && transcribeAgain?.passed == true && pacedCompletion?.passed == true && pacedCompletion?.reachedBound == true
                && pacedCancellation?.passed == true
        }
    }

    private struct Health: Codable { let version: String; let commit: String; let ready: Bool }
    private struct Rejection: Encodable { let status: Int; let code: String?; var rejectedAsIdentity: Bool { status == 401 && code == "invalid_identity" } }
    private struct Transcription: Encodable { let audioSeconds: Double; let streamedSeconds: Double; let finishToFinalMilliseconds: Int; let characters: Int; let anchors: Int; var reachedBound = false; var passed: Bool { anchors >= 2 } }
    private struct ProofLifetime: Encodable { var acceptedAtMinutes: [Int] = []; var expiredAtMinutes: Int?; var expired: Rejection? }
    private struct Cancellation: Encodable { let streamedSeconds: Double; let chargedSeconds: Double; let reservedAfterSettlement: Double; var passed: Bool { reservedAfterSettlement == 0 && chargedSeconds > 0 } }

    private static let languages = ["en", "sv"]
    private static let vocabulary = (1...57).map { "ProjectTerm\($0)" }
    private static let pacedSeconds = AccessGrant.progressiveAudioSeconds + 10

    static func runAndExit() -> Never {
        Task {
            var receipt = Receipt()
            do {
                try await run(&receipt)
            } catch {
                receipt.failure = describe(error)
            }
            receipt.passed = receipt.failure == nil && receipt.allPassed
            let path = ProcessInfo.processInfo.environment["MUMLA_ACCESS_PROBE_RECEIPT"] ?? "/tmp/mumla-access-probe.json"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(receipt).write(to: URL(fileURLWithPath: path), options: .atomic)
            exit(receipt.passed ? 0 : 1)
        }
        dispatchMain()
    }

    private static func run(_ receipt: inout Receipt) async throws {
        guard let configuration = AccessConfiguration.main(),
              let fixture = ProcessInfo.processInfo.environment["MUMLA_ACCESS_PROBE_FIXTURE"].map(URL.init(fileURLWithPath:))
        else { throw AccessFailure.serviceUnavailable }
        receipt.origin = configuration.origin.absoluteString
        let transport = AccessClient.makeTransport()
        let (healthData, _) = try await transport.data(from: configuration.origin.appending(path: "healthz"))
        receipt.health = try JSONDecoder().decode(Health.self, from: healthData)
        if let minutes = ProcessInfo.processInfo.environment["MUMLA_ACCESS_PROBE_PROOF_LIFETIME_MINUTES"].flatMap(Int.init) {
            receipt.stage = "proof-lifetime"
            receipt.proofLifetime = try await proofLifetime(configuration, transport: transport, maximumMinutes: minutes)
            return
        }

        let store = ProbeSessionStore()
        guard let client = AccessClient.live(store: store) else { throw AccessFailure.serviceUnavailable }
        do {
            try await exercise(client, store: store, configuration: configuration, fixture: fixture, transport: transport, receipt: &receipt)
        } catch {
            await client.endSession()
            throw error
        }
        await client.endSession()
    }

    private static func exercise(
        _ client: AccessClient, store: ProbeSessionStore, configuration: AccessConfiguration,
        fixture: URL, transport: URLSession, receipt: inout Receipt
    ) async throws {
        receipt.stage = "cloudkit-proof"
        let identity = CloudKitAccessIdentity(configuration)
        let proof: String
        do { proof = try await identity.webAuthToken() } catch {
            receipt.cloudKitError = (error as? CKError)?.code.rawValue
            throw error
        }
        receipt.stage = "proof-exchange"
        let accepted = try await enroll(proof, origin: configuration.origin, transport: transport)
        receipt.freshProof = accepted.rejection
        receipt.replayedProof = try await enroll(proof, origin: configuration.origin, transport: transport).rejection
        let forged = String(proof.dropLast(8)) + String(proof.suffix(8).reversed())
        receipt.forgedProof = try await enroll(forged, origin: configuration.origin, transport: transport).rejection
        if let token = accepted.token { await revoke(token, origin: configuration.origin, transport: transport) }

        receipt.stage = "client-enrollment"
        let access = MumlaAccess(client: client)
        _ = try await client.allowance()
        receipt.enrolledNatively = store.hasSession
        receipt.stage = "transcribe-again"

        let original = try OriginalAudioWriter.encode(contentsOf: fixture)
        defer { try? FileManager.default.removeItem(at: original) }
        let wav = try await OriginalAudio.providerWAV(from: original, fileType: .caf)
        let started = ContinuousClock.now
        let result = try await AccessTranscriber(access: access).transcribe(wav: wav, languageHints: languages, customVocabulary: vocabulary)
        receipt.transcribeAgain = Transcription(
            audioSeconds: Double(wav.count - 44) / Double(2 * AccessGrant.sampleRate), streamedSeconds: 0,
            finishToFinalMilliseconds: milliseconds(started.duration(to: .now)), characters: result.text.count, anchors: anchors(in: result.text)
        )

        let paced = pacedPCM(speech: wav.dropFirst(44))
        receipt.stage = "paced-completion"
        receipt.pacedCompletion = try await stream(paced, access: access, cancel: false).completion
        receipt.stage = "paced-cancellation"
        let before = try await client.allowance()
        let cancellation = try await stream(paced, access: access, cancel: true)
        let settled = try await settledAllowance(client)
        receipt.pacedCancellation = Cancellation(
            streamedSeconds: cancellation.streamedSeconds,
            chargedSeconds: (settled.used - before.used) / .seconds(1),
            reservedAfterSettlement: settled.reserved / .seconds(1)
        )
    }

    private static func pacedPCM(speech: Data) -> Data {
        let cycle = 5 * AccessGrant.sampleRate * 2
        var pcm = Data(capacity: pacedSeconds * AccessGrant.sampleRate * 2)
        while pcm.count < pacedSeconds * AccessGrant.sampleRate * 2 {
            let phrase = speech.prefix(cycle)
            pcm.append(phrase)
            pcm.append(Data(repeating: 0, count: cycle - phrase.count))
        }
        return pcm
    }

    private static func stream(_ pcm: Data, access: MumlaAccess, cancel: Bool) async throws -> (completion: Transcription?, streamedSeconds: Double) {
        let grant = Task { try await access.grant(maximumAudioSeconds: AccessGrant.progressiveAudioSeconds) }
        let limitReached = OSAllocatedUnfairLock(initialState: false)
        let dictation = RealtimeDictation(session: RealtimeDictationProviderConfiguration(
            grant: grant, customVocabulary: vocabulary, languageHints: languages,
            onAudioLimitReached: { limitReached.withLock { $0 = true } }
        ).makeSession())
        let bytesPerSecond = dictation.sampleRate * 2
        let chunk = bytesPerSecond / 10
        let started = ContinuousClock.now
        var appended = 0
        for offset in stride(from: 0, to: pcm.count, by: chunk) where !limitReached.withLock({ $0 }) {
            let end = min(offset + chunk, pcm.count)
            try await Task.sleep(until: started.advanced(by: .seconds(Double(end) / Double(bytesPerSecond))), clock: .continuous)
            dictation.append(pcm.subdata(in: offset..<end))
            appended = end
        }
        let streamed = Double(appended) / Double(bytesPerSecond)
        if cancel {
            await dictation.cancel()
            return (nil, streamed)
        }
        let stopped = ContinuousClock.now
        let completion = await RealtimeDictationCompletion.finish(dictation)
        if let error = completion.error { throw error }
        let text = completion.text ?? ""
        return (Transcription(audioSeconds: streamed, streamedSeconds: streamed, finishToFinalMilliseconds: milliseconds(stopped.duration(to: .now)),
                              characters: text.count, anchors: anchors(in: text), reachedBound: limitReached.withLock { $0 }), streamed)
    }

    private static func settledAllowance(_ client: AccessClient) async throws -> MumlaAccess.Allowance {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            let allowance = try await client.allowance()
            if allowance.reserved == .zero || ContinuousClock.now > deadline { return allowance }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private static func proofLifetime(_ configuration: AccessConfiguration, transport: URLSession, maximumMinutes: Int) async throws -> ProofLifetime {
        let proof = try await CloudKitAccessIdentity(configuration).webAuthToken()
        let started = ContinuousClock.now
        var lifetime = ProofLifetime()
        while true {
            let minutes = Int(started.duration(to: .now) / .seconds(60))
            let enrollment = try await enroll(proof, origin: configuration.origin, transport: transport)
            if let token = enrollment.token {
                await revoke(token, origin: configuration.origin, transport: transport)
                lifetime.acceptedAtMinutes.append(minutes)
            } else {
                lifetime.expiredAtMinutes = minutes
                lifetime.expired = enrollment.rejection
                return lifetime
            }
            guard minutes + 10 <= maximumMinutes else { return lifetime }
            try await Task.sleep(for: .seconds(600))
        }
    }

    private struct Enrollment { let token: String?; let rejection: Rejection }

    private static func enroll(_ proof: String, origin: URL, transport: URLSession) async throws -> Enrollment {
        var request = URLRequest(url: origin.appending(path: "/v1/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["web_auth_token": proof])
        let (data, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let code = (body?["error"] as? [String: Any])?["code"] as? String
        return Enrollment(token: status == 201 ? body?["token"] as? String : nil, rejection: Rejection(status: status, code: code))
    }

    private static func revoke(_ token: String, origin: URL, transport: URLSession) async {
        var request = URLRequest(url: origin.appending(path: "/v1/session"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await transport.data(for: request)
    }

    private static func describe(_ error: any Error) -> String {
        var parts = [summary(error)]
        var current = error
        while let realtime = current as? RealtimeDictationError {
            switch realtime {
            case .connectionFailed(let underlying), .streamFailed(let underlying), .commitFailed(let underlying):
                parts.append(summary(underlying))
                current = underlying
            default:
                return parts.joined(separator: " <- ")
            }
        }
        return parts.joined(separator: " <- ")
    }

    private static func summary(_ error: any Error) -> String {
        let diagnostic = DiagnosticError(error)
        var fields = [diagnostic.domain, String(diagnostic.code), diagnostic.kind].compactMap(\.self)
        if case SpeechKitError.httpFailure(_, let body) = error,
           let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
           let code = (object["error"] as? [String: Any])?["code"] as? String,
           code.count <= 64, code.allSatisfy({ $0.isASCII && ($0.isLowercase || $0 == "_") }) {
            fields.append(code)
        }
        return fields.joined(separator: ":")
    }

    private static func anchors(in text: String) -> Int {
        let normalized = text.lowercased()
        return ["merge", "main", "build"].filter { normalized.contains($0) }.count
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

private nonisolated final class ProbeSessionStore: AccessSessionStore {
    private let session = Mutex<StoredAccessSession?>(nil)

    var hasSession: Bool { session.withLock { $0 != nil } }
    func load() throws -> StoredAccessSession? { session.withLock { $0 } }
    func save(_ session: StoredAccessSession) throws { self.session.withLock { $0 = session } }
    func delete() throws { session.withLock { $0 = nil } }
}
#endif
