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
        let reclaimedOriginal: Bool
        let heldOriginalRetained: Bool
        let cloudCaptureAndChunksVerified: Bool
        let audioBeforeCaptureVisibilityVerified: Bool
        let receiptReplayVerified: Bool
        let conflictIsolationVerified: Bool
    }

    static func run() async throws {
        try ProjectedCloudTransportProbe.requireDevelopmentSignature()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationLibraryProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = CKContainer(identifier: MumlaDataStore.cloudContainerIdentifier).privateCloudDatabase
        let store = try DictationLibraryStore(directory: root.appendingPathComponent("producer"), source: "synthetic-development-probe", capacityBytes: 16 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
        guard try await store.refresh() == nil, let session = store.accountSession() else { throw AudioArchiveError.invalidRecording }
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
            let heldPlan = DictationPlan(unverifiedProfile: profile, context: .chat, capabilities: capabilities)
            let heldWriter = try await store.beginCapture(plan: heldPlan)
            let writer = try await store.beginCapture(plan: plan)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_820),
                  let samples = unsafe buffer.floatChannelData?[0] else { throw AudioArchiveError.invalidRecording }
            buffer.frameLength = 8_820
            unsafe samples.initialize(repeating: 0.1, count: 8_820)
            try heldWriter.configure(format: format)
            heldWriter.append(buffer)
            let held = try await heldWriter.finish()
            let heldOriginal = try Data(contentsOf: heldWriter.originalURL)
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
            let observer = try DictationArchive(directory: root.appendingPathComponent("publication-observer"), capacityBytes: 16 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
            _ = try await observer.refresh()
            guard try await observer.entries().allSatisfy({ $0.id != capture.id }) else { throw AudioArchiveError.invalidRecording }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await store.publishPending() }
                group.addTask {
                    for _ in 0..<120 {
                        try Task.checkCancellation()
                        _ = try await observer.refresh()
                        if try await observer.entries().contains(where: { $0.id == capture.id }) {
                            let original = try await observer.original(for: capture.id)
                            let bytes = try Data(contentsOf: original)
                            let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                            guard bytes.count == originalCount, sha == capture.originalSHA256 else { throw AudioArchiveError.invalidRecording }
                            return
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    throw AudioArchiveError.invalidRecording
                }
                try await group.waitForAll()
            }
            let uploaded = try await store.status()
            let publicationIDs = created.filter { $0.recordName.hasPrefix("capture-") || $0.recordName.hasPrefix("result-") || $0.recordName.hasPrefix("original-") }
            let beforeReplay = try await database.records(for: publicationIDs)
            guard try await store.reseedPublication(session: session) == 1 else { throw AudioArchiveError.invalidRecording }
            let replayed = try await store.publishPending()
            guard replayed.pendingCaptureCount == 0, replayed.failures.isEmpty else { throw AudioArchiveError.invalidRecording }
            let afterReplay = try await database.records(for: publicationIDs)
            for id in publicationIDs {
                guard let before = beforeReplay[id], let after = afterReplay[id],
                      try before.get().recordChangeTag == after.get().recordChangeTag,
                      try before.get().recordChangeTag != nil else { throw AudioArchiveError.invalidRecording }
            }
            guard uploaded.pendingCaptureCount == 0, uploaded.failures.isEmpty,
                  FileManager.default.fileExists(atPath: writer.originalURL.path) else { throw AudioArchiveError.invalidRecording }
            let tightStore = try DictationLibraryStore(directory: root.appendingPathComponent("producer"), source: "synthetic-development-probe", capacityBytes: uploaded.usedBytes, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
            _ = try await tightStore.refresh()
            let reclaimed = try await tightStore.publishPending()
            guard reclaimed.pendingCaptureCount == 0, reclaimed.failures.isEmpty, reclaimed.usedBytes < uploaded.usedBytes,
                  !FileManager.default.fileExists(atPath: writer.originalURL.path),
                  try Data(contentsOf: heldWriter.originalURL) == heldOriginal,
                  try await tightStore.heldCaptures().contains(where: { $0.id == held.id && $0.originalURL != nil }) else { throw AudioArchiveError.invalidRecording }
            let cloudIDs = [CKRecord.ID(recordName: "capture-\(capture.id.uuidString)", zoneID: HistoryCloudSchema.zoneID)]
                + (0..<chunks).map { CKRecord.ID(recordName: "original-\(capture.id.uuidString)-\($0)", zoneID: HistoryCloudSchema.zoneID) }
            let cloudRecords = try await database.records(for: cloudIDs, desiredKeys: [])
            for id in cloudIDs {
                guard let record = cloudRecords[id] else { throw AudioArchiveError.invalidRecording }
                _ = try record.get()
            }
            let library = try await MainActor.run {
                UnifiedDictationLibrary(store: try UnifiedDictationLibrary.makeStore(rootDirectory: root.appendingPathComponent("host")),
                    rootDirectory: root.appendingPathComponent("host"), background: AppDictationBackgroundExecution(), vocabulary: { [term] },
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
            let conflicts = try DictationLibraryStore(directory: root.appendingPathComponent("conflicts"), source: "synthetic-conflict-probe", capacityBytes: 16 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
            _ = try await conflicts.refresh()
            guard let conflictSession = conflicts.accountSession() else { throw AudioArchiveError.invalidRecording }
            try await conflicts.saveProfile(profile, session: conflictSession)
            let conflictPlan = try await conflicts.makePlan(context: .chat, capabilities: capabilities)
            var syntheticCaptures: [DictationCapture] = []
            for _ in 0..<2 {
                let writer = try await conflicts.beginCapture(plan: conflictPlan)
                try writer.configure(format: format)
                writer.append(buffer)
                let capture = try await writer.finish()
                syntheticCaptures.append(capture)
                created.append(CKRecord.ID(recordName: "capture-\(capture.id.uuidString)", zoneID: HistoryCloudSchema.zoneID))
                let chunkCount = Int(((capture.originalByteCount ?? 0) - 1) / (8 * 1_024 * 1_024) + 1)
                created.append(contentsOf: (0..<chunkCount).map { CKRecord.ID(recordName: "original-\(capture.id.uuidString)-\($0)", zoneID: HistoryCloudSchema.zoneID) })
            }
            let healthy = syntheticCaptures[0]
            let conflicting = syntheticCaptures[1]
            let conflictID = CKRecord.ID(recordName: "capture-\(conflicting.id.uuidString)", zoneID: HistoryCloudSchema.zoneID)
            let different = CKRecord(recordType: DictationLibrarySchema.captureRecordType, recordID: conflictID)
            let differentPayload = Data("synthetic different content".utf8)
            different.encryptedValues[DictationLibrarySchema.payloadKey] = differentPayload
            different.encryptedValues[DictationLibrarySchema.contentHashKey] = SHA256.hash(data: differentPayload).map { String(format: "%02x", $0) }.joined()
            _ = try await database.save(different)
            let conflictStatus = try await conflicts.publishPending()
            guard conflictStatus.pendingCaptureCount == 1, conflictStatus.failures.count == 1,
                  conflictStatus.failures.first?.captureID == conflicting.id,
                  conflictStatus.failures.first?.error == .contentConflict(conflictID.recordName) else { throw AudioArchiveError.invalidRecording }
            _ = try await database.record(for: CKRecord.ID(recordName: "capture-\(healthy.id.uuidString)", zoneID: HistoryCloudSchema.zoneID))
            let receipt = Receipt(passed: true, publishedCaptures: 1, publishedResults: 1, metadataInitiallyHadAudio: hadAudio, restartedCaptureCount: replay.newCaptureCount, originalByteCount: bytes.count, originalSHA256: sha, exportComplete: export.manifest.complete, nativeSearchVerified: true, nativeOriginalVerified: true, backupRestoreVerified: backupVerified, reclaimedOriginal: true, heldOriginalRetained: true, cloudCaptureAndChunksVerified: true, audioBeforeCaptureVisibilityVerified: true, receiptReplayVerified: true, conflictIsolationVerified: true)
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
