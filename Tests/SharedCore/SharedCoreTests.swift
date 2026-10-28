import DictationLibrary
import Foundation
import Testing
import SpeechKit

@Suite("Transcription provider contracts")
struct TranscriptionProviderContractTests {
    @Test func batchDictationBuildsFromAnAccessGrantAlone() throws {
        let grant = AccessGrant(token: "synthetic-grant", audioLimitSamples: 16_000, origin: URL(string: "https://access.test")!)
        _ = try TranscriptionEngineFactory.makeBatchEngine(access: try grant.speechAccess())
    }

    @Test func everyProfileDictatesWithMAITranscribe2WithoutCleanup() throws {
        var profile = DictationProfile(languages: ["sv"], dictionary: ["Mumla"])
        profile.preferredModel = TranscriptionProviderType.elevenLabsScribeV2.libraryModelID
        profile.cleanupEnabled = true
        let plan = DictationPlan(unverifiedProfile: profile, context: .prose, capabilities: try UnifiedDictationLibrary.capabilities())
        #expect(plan.effectiveModel == TranscriptionProviderType.dictation.libraryModelID)
        #expect(!plan.cleanupEnabled)
        #expect(plan.providerOptions == ["transcribeStyle": "clean"])
    }

    @Test func historicalModelIDsStayReadable() {
        #expect(TranscriptionProviderType(libraryModelID: "elevenlabs/scribe_v2/batch") == .elevenLabsScribeV2)
    }
}

@Suite("Spoken languages owner")
struct SpokenLanguagesOwnerTests {
    private static func owner(
        _ state: DictationProfileState, consentKnown: Bool = false, iCloudSignedOut: Bool = false
    ) -> SpokenLanguagesOwner {
        UnifiedDictationLibrary.spokenLanguagesOwner(for: state, archivalConsentKnown: consentKnown, iCloudSignedOut: iCloudSignedOut)
    }

    private static func ready(_ languages: [String]) -> DictationProfileState {
        .ready(DictationProfileSnapshot(
            accountIdentifier: "synthetic-account", refreshedAt: .now,
            profile: DictationProfile(languages: languages, dictionary: [])
        ))
    }

    @Test func withoutASharedProfileTheLocalListOwnsLanguages() {
        #expect(Self.owner(.absent) == .local)
    }

    @Test func signedOutWithConsentUnknownEditsTheLocalList() {
        #expect(Self.owner(.unavailable, iCloudSignedOut: true) == .local)
    }

    @Test func aReadySharedProfileOwnsLanguagesIncludingAutomatic() {
        #expect(Self.owner(Self.ready(["sv", "en"]), consentKnown: true) == .profile(["sv", "en"]))
        #expect(Self.owner(Self.ready([])) == .profile([]))
    }

    @Test func anUnloadedProfileIsReadOnlyWithItsReason() {
        #expect(Self.owner(.unverified, consentKnown: true) == .unavailable(.checking))
        #expect(Self.owner(.unavailable, consentKnown: true) == .unavailable(.unreachable))
        #expect(Self.owner(.unavailable, consentKnown: true, iCloudSignedOut: true) == .unavailable(.signedOut))
    }

    @Test func theLocalListKeepsOneLanguageWhileAProfileMayGoToAutomatic() {
        #expect(SpokenLanguagesOwner.local.edit([]) == .ignored)
        #expect(SpokenLanguagesOwner.local.edit(["sv"]) == .local(["sv"]))
        #expect(SpokenLanguagesOwner.profile(["sv"]).edit([]) == .profile([]))
        #expect(SpokenLanguagesOwner.unavailable(.checking).edit(["sv"]) == .ignored)
    }

    @Test func absentWithConsentKnownIsReadOnly() {
        #expect(Self.owner(.absent, consentKnown: true) == .unavailable(.noSharedProfile))
    }

    @Test func consentBecomingKnownMovesDictationAndTheEditorTogether() {
        for state: DictationProfileState in [.absent, .unverified, .unavailable] {
            #expect(UnifiedDictationLibrary.dictationProfileSource(for: state, archivalConsentKnown: false) == .localSettings)
            #expect(Self.owner(state) == .local)
            #expect(UnifiedDictationLibrary.dictationProfileSource(for: state, archivalConsentKnown: true) == .unverifiedProfile)
            guard case .unavailable = Self.owner(state, consentKnown: true) else {
                Issue.record("Settings stays editable while dictation uses an unverified plan")
                continue
            }
        }
    }
}

@Suite("PCM WAV framing")
struct PCM16WAVFileTests {
    @Test func wrapsPCM16DataInMinimalWAVContainer() throws {
        let pcm = Data([0x00, 0x00, 0xff, 0x7f])
        let wav = try RealtimePCM16WAVFile.data(pcmData: pcm, sampleRate: 16_000)

        #expect(wav.count == 44 + pcm.count)
        #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        #expect(String(data: wav[36..<40], encoding: .ascii) == "data")
        #expect(littleEndianUInt32(in: wav, at: 24) == 16_000)
        #expect(littleEndianUInt32(in: wav, at: 40) == UInt32(pcm.count))
    }

    @Test func rejectsInvalidWAVInputs() {
        #expect(throws: RealtimePCM16WAVFileWriterError.self) {
            _ = try RealtimePCM16WAVFile.data(pcmData: Data([0x00, 0x00]), sampleRate: 0)
        }
        #expect(throws: RealtimePCM16WAVFileWriterError.self) {
            _ = try RealtimePCM16WAVFile.data(pcmData: Data(), sampleRate: 16_000)
        }
    }

    private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
