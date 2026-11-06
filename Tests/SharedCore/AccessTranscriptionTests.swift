import Foundation
import SpeechKit
import Testing

@Suite("Access transcription rules")
struct AccessTranscriptionTests {
    @Test func theSampleBudgetSendsOnlyThePrefixTheGrantAdmits() {
        var budget = AudioSampleBudget(samples: 3)

        #expect(budget.admit(Data([1, 1, 2, 2])) == Data([1, 1, 2, 2]))
        #expect(!budget.isSpent)
        #expect(budget.admit(Data([3, 3, 4, 4])) == Data([3, 3]))
        #expect(budget.isSpent)
        #expect(budget.admit(Data([5, 5])).isEmpty)
    }

    @Test func theStartMessageCarriesTheDictionarysLeadingTermsWithinItsBudget() throws {
        let small = ["Mumla", "Lund", "quote \" and backslash \\"]
        #expect(AccessStream.leadingTerms(of: small) == small)

        let large = (0..<6_000).map { "term \($0) " + String(repeating: "x", count: 40) }
        let sent = AccessStream.leadingTerms(of: large)
        #expect(!sent.isEmpty && sent.count < large.count)
        #expect(sent == Array(large.prefix(sent.count)))
        #expect(try JSONEncoder().encode(sent).count <= AccessStream.vocabularyBudgetBytes)
        #expect(try JSONEncoder().encode(Array(large.prefix(sent.count + 1))).count > AccessStream.vocabularyBudgetBytes)
    }

    @Test func onlyCanonicalMonoPCM16AtTheGrantRateIsMeasured() throws {
        let pcm = Data(repeating: 0, count: 32_000)
        let canonical = try RealtimePCM16WAVFile.data(pcmData: pcm, sampleRate: 16_000)

        #expect(PCM16WAVHeader.sampleCount(of: canonical, sampleRate: 16_000) == 16_000)
        #expect(PCM16WAVHeader.sampleCount(of: try RealtimePCM16WAVFile.data(pcmData: pcm, sampleRate: 48_000), sampleRate: 16_000) == nil)
        #expect(PCM16WAVHeader.sampleCount(of: canonical.dropLast(2), sampleRate: 16_000) == nil)
        var stereo = canonical
        stereo[22] = 2
        #expect(PCM16WAVHeader.sampleCount(of: stereo, sampleRate: 16_000) == nil)
    }

    @Test(arguments: [
        (AccessStreamFailure.refused(status: 401), TranscriptionRecovery.resendArchived),
        (AccessStreamFailure.refused(status: 503), .resendArchived),
        (AccessStreamFailure.refused(status: 503, dictationID: "d1"), .resendArchived),
        (AccessStreamFailure.refused(status: 502), .keepForRetry),
        (AccessStreamFailure.refused(status: 413), .keepForRetry),
        (AccessStreamFailure.invalidReply, .keepForRetry),
        (URLError(.timedOut), .keepForRetry),
        (RealtimeDictationError.streamFailed(AccessStreamFailure.refused(status: 503)), .resendArchived),
        (RealtimeDictationError.streamFailed(AccessStreamFailure.refused(status: 502)), .keepForRetry),
        (RealtimeDictationError.streamFailed(URLError(.networkConnectionLost)), .keepForRetry),
        (RealtimeDictationError.connectionFailed(AccessStreamFailure.refused(status: 401)), .resendArchived),
        (RealtimeDictationError.connectionFailed(AccessFailure.allowanceExhausted), .refused(.allowanceExhausted)),
        (RealtimeDictationError.connectionFailed(URLError(.cannotConnectToHost)), .resendArchived),
        (RealtimeDictationError.connectionFailed(CancellationError()), .canceled),
        (RealtimeDictationNotStarted(), .resendArchived),
        (AccessFailure.allowanceBusy, .refused(.allowanceBusy)),
        (CancellationError(), .canceled),
    ] as [(any Error & Sendable, TranscriptionRecovery)])
    func onlyAttemptsThatNeverReachedTheProviderAreResent(error: any Error & Sendable, recovery: TranscriptionRecovery) {
        #expect(TranscriptionRecovery(after: error) == recovery)
    }

    @Test func aRefusalReportsTheServiceDictationIDItCarries() {
        let reported = DiagnosticError(AccessStreamFailure.refused(status: 502, dictationID: "d1")).metadata
        #expect(reported["error_code"] == "502")
        #expect(reported["service_dictation_id"] == "d1")
        #expect(DiagnosticError(AccessStreamFailure.refused(status: 502)).metadata["service_dictation_id"] == nil)
    }

    @MainActor
    @Test func transcribeAgainReservesUpToTheBatchBoundAndRefusesLongerRecordingsWithoutAsking() async throws {
        let service = StubAccessService()
        service.reply("POST /v1/dictations", 402, #"{"error":{"code":"allowance_exhausted"}}"#)
        let store = MemoryAccessSessionStore(.init(token: "s0", expiresAt: .now + 20 * 86_400, account: FakeAccessIdentity.account, subject: FakeAccessIdentity.subject))
        let transcriber = AccessTranscriber(access: MumlaAccess(client: service.client(store: store)))
        func wav(seconds: Int) throws -> Data {
            try RealtimePCM16WAVFile.data(pcmData: Data(count: seconds * AccessGrant.sampleRate * 2), sampleRate: AccessGrant.sampleRate)
        }

        await #expect(throws: AccessFailure.allowanceExhausted) {
            try await transcriber.transcribe(wav: wav(seconds: AccessGrant.maximumAudioSeconds), languageHints: [], customVocabulary: [])
        }
        await #expect(throws: AccessTranscriptionError.recordingTooLong) {
            try await transcriber.transcribe(wav: wav(seconds: AccessGrant.maximumAudioSeconds + 1), languageHints: [], customVocabulary: [])
        }

        let reservations = service.requests.filter { $0.route == "POST /v1/dictations" }
        #expect(try reservations.map { try $0.json([String: Int].self) } == [["maximum_audio_seconds": AccessGrant.maximumAudioSeconds]])
    }
}
