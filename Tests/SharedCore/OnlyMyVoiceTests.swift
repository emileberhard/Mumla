import AVFoundation
import Foundation
import Testing

private enum SpeakerFixtures {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Reference: Decodable {
        let modelVersion: String
        let syntheticFbankRows: [String: [Float]]
        let syntheticFbankFrameCount: Int
        let embeddings: [String: [Float]]
    }

    static func reference() throws -> Reference {
        try JSONDecoder().decode(Reference.self, from: Data(contentsOf: repository.appending(path: "Tests/SharedCore/SpeakerModelReference.json")))
    }

    static func modelURL() throws -> URL {
        try #require(Bundle.allBundles.lazy.compactMap { $0.url(forResource: "SpeakerModel", withExtension: "mlmodelc") }.first)
    }

    static func embedder() throws -> SpeakerEmbedder {
        try SpeakerEmbedder(modelURL: modelURL())
    }

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

nonisolated private func axis(_ index: Int, _ weight: Float = 1, plus other: Int? = nil, _ otherWeight: Float = 0) -> SpeakerEmbedding {
    var values = [Float](repeating: 0, count: 256)
    values[index] = weight
    if let other { values[other] += otherWeight }
    return SpeakerEmbedding(normalizing: values)
}

@Suite("Speaker model")
struct SpeakerModelTests {
    @Test func theFilterbankMatchesKaldiOnTheReferenceSignal() throws {
        let reference = try SpeakerFixtures.reference()
        let samples = (0..<16_000).map { n -> Float in
            let n = Double(n)
            let noise = Double((Int(n) * 7_919) % 1_000) / 1_000 - 0.5
            return Float(0.3 * sin(2 * .pi * 220 * n / 16_000) + 0.2 * sin(2 * .pi * 1_375 * n / 16_000 + 0.5) + 0.05 * noise)
        }
        let features = try KaldiFilterbank.features(of: samples)
        #expect(features.count == reference.syntheticFbankFrameCount * KaldiFilterbank.binCount)
        for (row, expected) in reference.syntheticFbankRows {
            let start = try #require(Int(row)) * KaldiFilterbank.binCount
            let produced = features[start..<start + KaldiFilterbank.binCount]
            #expect(zip(produced, expected).allSatisfy { abs($0 - $1) < 0.01 }, "row \(row)")
        }
    }

    @Test func theBundledModelEmbedsSpeechLikeTheReference() async throws {
        let reference = try SpeakerFixtures.reference()
        #expect(reference.modelVersion == SpeakerEmbedder.modelVersion)
        let embedder = try SpeakerFixtures.embedder()
        for (name, expected) in reference.embeddings {
            let produced = try await embedder.embedding(of: Array(try SpeakerFixtures.speech(name).prefix(SpeakerEmbedder.windowSamples)))
            #expect(produced.similarity(to: SpeakerEmbedding(normalizing: expected)) >= 0.99, "\(name)")
        }
    }
}

@Suite("Voice watch")
struct VoiceWatchTests {
    @Test func piecesEndAtPausesAndAtTheWindow() {
        var signal = [Float](repeating: 0.001, count: 16_000)
        for _ in 0..<3 {
            signal += (0..<32_000).map { 0.3 * sin(Float($0) * 0.2) }
            signal += [Float](repeating: 0.001, count: 16_000)
        }
        signal += (0..<400_000).map { 0.3 * sin(Float($0) * 0.2) }
        var segmenter = VoicedPieceSegmenter()
        var pieces: [Range<Int>] = []
        for start in stride(from: 0, to: signal.count, by: 1_600) {
            pieces += segmenter.append(Array(signal[start..<min(start + 1_600, signal.count)]))
        }
        pieces += segmenter.finish().map { [$0] } ?? []

        #expect(pieces.count == 6)
        for piece in pieces.prefix(3) { #expect(abs(piece.count - 32_000) <= 800) }
        #expect(pieces.dropFirst(3).map(\.count).prefix(2).allSatisfy { $0 <= 160_000 && $0 > 158_000 })
    }

    @Test func anotherVoiceIsHeardOnlyWhenOneSpeaks() async throws {
        let modelURL = try SpeakerFixtures.modelURL()
        func watch(_ names: [String]) async throws -> VoiceRecording {
            let watch = VoiceWatch(modelURL: modelURL)
            var samples: [Float] = []
            for name in names { samples += try SpeakerFixtures.speech(name) + SpeakerFixtures.silence }
            let pcm = SpeakerFixtures.pcm16(samples)
            for offset in stride(from: 0, to: pcm.count, by: 3_200) { watch.append(pcm.subdata(in: offset..<min(offset + 3_200, pcm.count))) }
            watch.finish()
            return try await watch.recording
        }

        let one = try await watch(["en-developer-message", "en-short-long-rushed"])
        #expect(one.isComplete && one.pieces.count >= 2)
        #expect(!one.otherVoiceHeard)
        #expect(try await one.learningCandidate() != nil)

        let two = try await watch(["en-teen-note", "en-landlord-email"])
        #expect(two.otherVoiceHeard)
        #expect(try await two.learningCandidate() == nil)
    }
}

@Suite("Voice filter")
struct VoiceFilterTests {
    private func phrase(_ speaker: Int, _ text: String, seconds: Double, at start: Int = 0) -> VoicePhrase {
        let words = stride(from: 0, to: Int(seconds * 1_000), by: 500).map { [start + $0, 400] }
        return VoicePhrase(speaker: speaker, text: text, words: words)
    }

    @Test func labelsMergeCloseWordsAndKeepTheLongestEvidenceFirst() {
        let labels = VoiceFilter.labels(in: [
            VoicePhrase(speaker: 0, text: "a", words: [[0, 400], [500, 300]]),
            VoicePhrase(speaker: 1, text: "b", words: [[900, 200]]),
            VoicePhrase(speaker: 0, text: "c", words: [[2_000, 1_500], [9, -1]]),
        ])
        #expect(labels == [
            SpeakerLabel(speaker: 0, speechMilliseconds: 2_300, evidence: [1_950..<3_550, 0..<850]),
            SpeakerLabel(speaker: 1, speechMilliseconds: 200, evidence: [850..<1_150]),
        ])
        #expect(labels[0].isJudged && !labels[1].isJudged)
        #expect(labels[0].evidenceSamples(sampleRate: 16_000).first == 31_200..<56_800)
    }

    @Test func evidenceStopsAtTheModelWindow() {
        let label = VoiceFilter.labels(in: [VoicePhrase(speaker: 0, text: "a", words: [[0, 6_000], [7_000, 6_000]])])[0]
        #expect(label.evidence.reduce(0) { $0 + $1.count } == 10_000)
    }

    @Test func anotherPersonIsDroppedAndShortLabelsAreKept() {
        let phrases = [phrase(0, "Mine.", seconds: 5), phrase(1, "Theirs.", seconds: 3, at: 6_000), phrase(2, "Hm?", seconds: 1, at: 10_000)]
        let labels = VoiceFilter.labels(in: phrases)
        let kept = VoiceFilter.keptSpeakers(of: labels, embeddings: [0: axis(0), 1: axis(1)], profile: axis(0))
        #expect(kept == [0, 2])
        #expect(VoiceFilter.text(of: phrases, keeping: kept ?? []) == "Mine. Hm?")
    }

    @Test(arguments: [
        ("a split user", [0: axis(0), 1: axis(0, 0.6, plus: 2, 0.8)]),
        ("the user's other label matches only this recording", [0: axis(0, 0.8, plus: 3, 0.6), 1: axis(3)]),
        ("the user is not recognizably there", [0: axis(1), 1: axis(2)]),
        ("nothing long enough to judge", [:]),
    ] as [(String, [Int: SpeakerEmbedding])])
    func everythingIsKeptWhenNoLabelIsRejectedTwice(_ name: String, embeddings: [Int: SpeakerEmbedding]) {
        let labels = VoiceFilter.labels(in: [phrase(0, "a", seconds: 4), phrase(1, "b", seconds: 4, at: 5_000)])
        #expect(VoiceFilter.keptSpeakers(of: labels, embeddings: embeddings, profile: axis(0)) == nil, "\(name)")
    }

    @Test func repliesCarryPhrasesOrSayVoicesAreUnavailable() throws {
        #expect(try AccessStream.parse(#"{"type":"result","text":"Hej","id":"d1"}"#)
            == .reply(AccessStreamReply(text: "Hej", dictationID: "d1", phrases: nil)))
        #expect(try AccessStream.parse(#"{"type":"voices","text":"A\nB","phrases":[{"speaker":1,"text":"A","words":[[0,300]]}],"id":"d1"}"#)
            == .reply(AccessStreamReply(text: "A\nB", dictationID: "d1", phrases: [VoicePhrase(speaker: 1, text: "A", words: [[0, 300]])])))
        #expect(try AccessStream.parse(#"{"type":"voices_unavailable","id":"d1"}"#) == .unavailable)
        #expect(throws: AccessStreamFailure.invalidReply) { try AccessStream.parse(#"{"type":"voices","text":"A"}"#) }
    }
}

@Suite("Voice profile")
struct VoiceProfileTests {
    private func near(_ index: Int, _ seed: Int) -> SpeakerEmbedding {
        axis(index, 1, plus: 10 + seed, 0.2)
    }

    private func readyProfile() -> VoiceProfile {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        for seed in 0..<5 { profile.learn(near(0, seed), at: .now) }
        return profile
    }

    @Test func fiveConsistentCandidatesMakeItReadyAndAnOutlierIsDropped() throws {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        for seed in 0..<4 { profile.learn(near(0, seed), at: .now) }
        profile.learn(axis(1), at: .now)
        #expect(!profile.isReady && profile.candidates.count == 4)
        profile.learn(near(0, 4), at: .now)
        #expect(profile.isReady && profile.exemplars.count == 5)
        #expect(try #require(profile.mean).similarity(to: axis(0)) > 0.9)
    }

    @Test func aReadyProfileAcceptsOnlyItsOwnVoiceAndFreezes() {
        var profile = readyProfile()
        profile.learn(axis(1), at: .now)
        #expect(profile.exemplars.count == 5)
        for seed in 5..<40 { profile.learn(near(0, seed), at: .now) }
        #expect(profile.isFrozen && profile.exemplars.count == VoiceProfile.maximumExemplars)
    }

    @Test func itIsTrustedOnlyOnceEightRecentDictationsMatch() {
        var profile = readyProfile()
        for seed in 5..<12 { profile.learn(near(0, seed), at: .now) }
        #expect(profile.isReady && !profile.isTrusted && profile.trustedMean == nil)
        profile.learn(near(0, 12), at: .now)
        #expect(profile.isTrusted && profile.trustedMean != nil)
    }

    @Test func aSharedDeviceNeverTrustsTheProfile() {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        for seed in 0..<60 { profile.learn(seed.isMultiple(of: 2) ? near(0, seed) : near(1, seed), at: .now) }
        #expect(profile.isReady && !profile.isTrusted)
    }

    @Test func aProfileThatStopsMatchingStartsOver() {
        var profile = readyProfile()
        for seed in 5..<13 { profile.learn(near(0, seed), at: .now) }
        for seed in 0..<7 { profile.learn(near(1, seed), at: .now) }
        #expect(profile.isReady && !profile.isTrusted)
        let resetAt = Date.now
        profile.learn(near(1, 7), at: resetAt)
        #expect(!profile.isReady && profile.candidates.isEmpty && profile.createdAt == resetAt)
    }

    @Test func theStoreKeepsTheProfileOutOfBackupsAndForgetsItWhenTheModelChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "VoiceProfile.json")

        let store = VoiceProfileStore(accountDirectory: directory)
        for seed in 0..<5 { try await store.learn(near(0, seed), startedAt: .now) }
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile(forgottenAt: nil).isReady)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        try await store.forget(at: .now)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.profile(forgottenAt: nil).isReady == false)

        try JSONEncoder().encode(VoiceProfile(modelVersion: "an-older-model", createdAt: .now)).write(to: file)
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile(forgottenAt: nil).modelVersion == SpeakerEmbedder.modelVersion)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aForgetOnAnotherDeviceClearsTheProfileAndEarlierDictationsTeachNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let started = Date.now
        for seed in 0..<5 { try await store.learn(near(0, seed), startedAt: started) }
        #expect(try await store.profile(forgottenAt: started.addingTimeInterval(-60)).isReady)

        let forgottenAt = Date.now.addingTimeInterval(1)
        #expect(try await store.profile(forgottenAt: forgottenAt).isReady == false)
        try await store.learn(near(0, 5), startedAt: started)
        #expect(try await store.profile(forgottenAt: forgottenAt).candidates.isEmpty)
        try await store.learn(near(0, 6), startedAt: forgottenAt.addingTimeInterval(1))
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile(forgottenAt: forgottenAt).candidates.count == 1)
    }
}
