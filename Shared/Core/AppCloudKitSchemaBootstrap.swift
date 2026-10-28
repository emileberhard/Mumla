#if DEBUG && os(macOS)
import CloudKit
import DictationLibrary
import Foundation

/// Creates the custom zone, record type, and encrypted fields in CloudKit's
/// Development environment so they can be promoted in CloudKit Console.
nonisolated enum AppCloudKitSchemaBootstrap {
    static func runAndExit() -> Never {
        Task.detached(priority: .userInitiated) {
            await run()
        }
        dispatchMain()
    }

    private static func run() async {
        let database = CKContainer(
            identifier: MumlaDataStore.cloudContainerIdentifier
        ).privateCloudDatabase
        let zone = CKRecordZone(zoneID: HistoryCloudSchema.zoneID)
        let bootstrapID = UUID()
        let record = HistoryCloudSchema.makeRecord(from: HistoryCloudRecord(
            id: bootstrapID,
            text: "Schema bootstrap",
            createdAt: .now,
            providerDisplayName: "Bootstrap",
            deviceName: "Bootstrap",
            audioRecordingID: bootstrapID
        ))
        let vocabularyID = VocabularyTerm.identifier(for: "Schema bootstrap")!
        let vocabularyRecord = VocabularyCloudSchema.makeRecord(from: VocabularyCloudRecord(
            id: vocabularyID,
            text: "Schema bootstrap",
            normalizedText: "schema bootstrap",
            createdAt: .now,
            modifiedAt: .now,
            isDeleted: false,
            systemFields: nil
        ))

        let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("schema-bootstrap-\(bootstrapID)", isDirectory: true)
        let audioURL = assetDirectory.appendingPathComponent("\(bootstrapID).wav")
        defer { try? FileManager.default.removeItem(at: assetDirectory) }
        do {
            try ProjectedCloudTransportProbe.requireDevelopmentSignature()
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            let audio = try RealtimePCM16WAVFile.data(pcmData: Data(repeating: 0, count: 320), sampleRate: 16_000)
            try audio.write(to: audioURL, options: .atomic)
            let info = AudioRecordingInfo(
                id: bootstrapID, createdAt: .now, providerRawValue: "bootstrap",
                providerDisplayName: "Bootstrap", deviceName: "Bootstrap", source: "batch",
                durationMilliseconds: 10, byteCount: audio.count, sha256: AudioArchive.digest(audio),
                fileType: .wav
            )
            let audioRecord = try AudioCloudSchema.makeRecord(info: info, index: 0, fileURL: audioURL)
            _ = try await database.save(zone)
            _ = try await database.save(record)
            _ = try await database.save(vocabularyRecord)
            _ = try await database.save(audioRecord)
            let libraryRecords = try DictationLibrarySchema.schemaBootstrapRecords(assetDirectory: assetDirectory)
            for libraryRecord in libraryRecords {
                _ = try await database.save(libraryRecord)
            }
            for libraryRecord in libraryRecords {
                _ = try await database.deleteRecord(withID: libraryRecord.recordID)
            }
            _ = try await database.deleteRecord(withID: audioRecord.recordID)
            _ = try await database.deleteRecord(withID: HistoryCloudSchema.recordID(for: bootstrapID))
            _ = try await database.deleteRecord(withID: VocabularyCloudSchema.recordID(for: vocabularyID))
            print("CloudKit schema initialized — promote it to Production in CloudKit Console.")
            exit(0)
        } catch {
            print("CloudKit schema bootstrap failed: \(DiagnosticError(error).metadata)")
            exit(1)
        }
    }
}
#endif
