#if DEBUG && os(macOS)
import AVFAudio
import CloudKit
import CryptoKit
import DictationLibrary
import Foundation

nonisolated enum DictationLibraryCloudProbe {
    static func runAndExit() -> Never {
        Task.detached {
            do {
                try await run()
                print("Dictation library CloudKit probe passed")
                exit(0)
            } catch {
                let value = error as NSError
                print("Dictation library CloudKit probe failed: \(value.domain) \(value.code)")
                exit(1)
            }
        }
        dispatchMain()
    }

    struct Receipt: Codable {
        let passed: Bool
        let publishedCaptures: Int
        let publishedResults: Int
        let metadataInitiallyHadAudio: Bool
        let restartedCaptureCount: Int
        let originalByteCount: Int
        let originalSHA256: String
        let exportComplete: Bool
        let nativeSearchVerified: Bool
        let nativeOriginalVerified: Bool
        let backupRestoreVerified: Bool
    }

    static func run() async throws {
        try ProjectedCloudTransportProbe.requireDevelopmentSignature()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationLibraryProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = CKContainer(identifier: MumlaDataStore.cloudContainerIdentifier).privateCloudDatabase
        let store = try DictationLibraryStore(directory: root.appendingPathComponent("producer"), source: "synthetic-development-probe", capacityBytes: 16 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
        guard try await store.refresh() == nil, let session = await store.accountSession() else { throw AudioArchiveError.invalidRecording }
        var created: [CKRecord.ID] = []
        do {
            let term = "DictationProbe-\(UUID().uuidString)"
            guard let termID = VocabularyTerm.identifier(for: term), let normalized = VocabularyTerm.normalizedText(from: term) else { throw AudioArchiveError.invalidRecording }
            let vocabulary = VocabularyCloudSchema.makeRecord(from: VocabularyCloudRecord(id: termID, text: term, normalizedText: normalized, createdAt: .now, modifiedAt: .now, isDeleted: false, systemFields: nil))
            _ = try await database.save(vocabulary)
            created.append(vocabulary.recordID)
            let model = "openai/gpt-4o-mini-transcribe-2025-12-15/batch"
            let profile = DictationProfile(archiveEnabled: true, preferredModel: model, languages: ["sv", "en"], dictionary: [], cleanupEnabled: false, outputLanguage: nil, thinkingLevel: "low")
            try await store.saveProfile(profile, session: session)
            created.append(CKRecord.ID(recordName: DictationLibrarySchema.profileRecordName, zoneID: HistoryCloudSchema.zoneID))
            let capabilities = try DictationCapabilities(models: [model], fallbackModel: model, supportsCleanup: true)
            let plan = try await store.makePlan(context: .chat, capabilities: capabilities)
            guard plan.dictionary.contains(term), plan.languages == ["sv", "en"] else { throw AudioArchiveError.invalidRecording }
            let writer = try await store.beginCapture(plan: plan)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_820),
                  let samples = unsafe buffer.floatChannelData?[0] else { throw AudioArchiveError.invalidRecording }
            buffer.frameLength = 8_820
            unsafe samples.initialize(repeating: 0.1, count: 8_820)
            try writer.configure(format: format)
            writer.append(buffer)
            let capture = try await writer.finish()
            let result = DictationResultVersion(id: UUID(), captureID: capture.id, createdAt: .now, kind: .providerOutput, text: "Synthetic \(term) dictionary and archive integration check.", model: model, contextWasUsed: false, parentResultID: nil, plan: plan)
            try await store.addResult(result)
            created.append(CKRecord.ID(recordName: "capture-\(capture.id.uuidString)", zoneID: HistoryCloudSchema.zoneID))
            created.append(CKRecord.ID(recordName: "result-\(result.id.uuidString)", zoneID: HistoryCloudSchema.zoneID))
            let originalCount = try Data(contentsOf: writer.originalURL).count
            let chunks = (originalCount + 8 * 1_024 * 1_024 - 1) / (8 * 1_024 * 1_024)
            created.append(contentsOf: (0..<chunks).map { CKRecord.ID(recordName: "original-\(capture.id.uuidString)-\($0)", zoneID: HistoryCloudSchema.zoneID) })
            try await store.publishPending()
            guard try await store.status().pendingCaptureCount == 0 else { throw AudioArchiveError.invalidRecording }
            let library = try await MainActor.run {
                UnifiedDictationLibrary(store: try UnifiedDictationLibrary.makeStore(rootDirectory: root.appendingPathComponent("host")),
                    rootDirectory: root.appendingPathComponent("host"), vocabulary: { [term] },
                    onAccountChange: { _ in }, onExportRequested: { throw AudioArchiveError.invalidRecording },
                    onArchiveRoleChanged: {})
            }
            await library.refresh()
            try await library.refreshArchive()
            guard await library.entries.contains(where: { $0.id == capture.id }) else { throw AudioArchiveError.invalidRecording }
            var settingsOnly = profile
            settingsOnly.archiveEnabled = false
            settingsOnly.cleanupEnabled = true
            try await store.saveProfile(settingsOnly, session: session)
            await library.refresh()
            let settingsCapture = try await library.prepareCapture(context: .prose)
            guard let settingsCapture, settingsCapture.writer == nil, !settingsCapture.plan.archiveEnabled,
                  !settingsCapture.plan.cleanupEnabled, settingsCapture.plan.languages == profile.languages,
                  settingsCapture.plan.dictionary.contains(term) else { throw AudioArchiveError.invalidRecording }
            let directory = root.appendingPathComponent("reader")
            let archive = try DictationArchive(directory: directory, capacityBytes: 32 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
            _ = try await archive.refresh()
            guard let entry = try await archive.entries().first(where: { $0.id == capture.id }), entry.results.contains(where: { $0.id == result.id }) else { throw AudioArchiveError.invalidRecording }
            let hadAudio = entry.originalURL != nil
            guard !hadAudio else { throw AudioArchiveError.invalidRecording }
            let restarted = try DictationArchive(directory: directory, capacityBytes: 32 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
            let replay = try await restarted.refresh()
            guard replay.newCaptureCount == 0 else { throw AudioArchiveError.invalidRecording }
            let original = try await restarted.original(for: capture.id)
            let bytes = try Data(contentsOf: original)
            let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == originalCount, sha == capture.originalSHA256 else { throw AudioArchiveError.invalidRecording }
            let export = try await restarted.export(to: root.appendingPathComponent("exports"))
            guard export.manifest.files.contains(where: { $0.sha256 == sha && $0.byteCount == bytes.count }) else { throw AudioArchiveError.invalidRecording }
            guard let executable = Bundle.main.executableURL else { throw AudioArchiveError.invalidRecording }
            let search = try await command(executable, ["--dictation-library", "search", "--text", term, "--limit", "1"], root: root)
            let searchValue = try JSONDecoder().decode(NativeCatalog.self, from: search)
            guard searchValue.complete, searchValue.entries.first?.capture.id == capture.id else { throw AudioArchiveError.invalidRecording }
            let nativeOriginal = root.appendingPathComponent("native-original.caf")
            _ = try await command(executable, ["--dictation-library", "audio", "--id", capture.id.uuidString, "--output", nativeOriginal.path], root: root)
            guard try Data(contentsOf: nativeOriginal) == bytes else { throw AudioArchiveError.invalidRecording }
            var backupVerified = false
            if let path = ProcessInfo.processInfo.environment["MUMLA_BACKUP_PROBE_CLI"] {
                guard export.manifest.complete else { throw AudioArchiveError.invalidRecording }
                let backup = root.appendingPathComponent("backup")
                let restored = root.appendingPathComponent("restored")
                _ = try await command(URL(fileURLWithPath: path), ["backup", "--dest", backup.path, "--export", export.directory.path], root: root)
                _ = try await command(URL(fileURLWithPath: path), ["restore", "--dest", backup.path, "--account", export.manifest.account.hash, "--target", restored.path], root: root)
                for file in export.manifest.files {
                    let restoredBytes = try Data(contentsOf: restored.appendingPathComponent(file.path))
                    let restoredHash = SHA256.hash(data: restoredBytes).map { String(format: "%02x", $0) }.joined()
                    guard restoredHash == file.sha256, restoredBytes.count == file.byteCount else { throw AudioArchiveError.invalidRecording }
                }
                backupVerified = true
            }
            let receipt = Receipt(passed: true, publishedCaptures: 1, publishedResults: 1, metadataInitiallyHadAudio: hadAudio, restartedCaptureCount: replay.newCaptureCount, originalByteCount: bytes.count, originalSHA256: sha, exportComplete: export.manifest.complete, nativeSearchVerified: true, nativeOriginalVerified: true, backupRestoreVerified: backupVerified)
            let path = ProcessInfo.processInfo.environment["MUMLA_LIBRARY_PROBE_RECEIPT"] ?? "/tmp/mumla-library-probe.json"
            try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            for id in created.reversed() { _ = try? await database.deleteRecord(withID: id) }
            throw error
        }
        for id in created.reversed() { _ = try await database.deleteRecord(withID: id) }
    }

    private struct NativeCatalog: Decodable {
        let complete: Bool
        let entries: [Entry]
        struct Entry: Decodable {
            let capture: Capture
            struct Capture: Decodable { let id: UUID }
        }
    }

    private static func command(_ executable: URL, _ arguments: [String], root: URL) async throws -> Data {
        let output = root.appendingPathComponent("command-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AudioArchiveError.invalidRecording }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["MUMLA_TRANSPORT_PROBE"] = nil
        environment["MUMLA_LIBRARY_PROBE"] = nil
        environment["MUMLA_INIT_CLOUDKIT_SCHEMA"] = nil
        process.environment = environment
        process.standardOutput = file
        process.standardError = file
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { child in
                if child.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: AudioArchiveError.invalidRecording) }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        try file.synchronize()
        return try Data(contentsOf: output)
    }
}
#endif
