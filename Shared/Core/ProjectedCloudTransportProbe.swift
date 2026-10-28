#if DEBUG && os(macOS)
import CloudKit
import Foundation
import Security
import SwiftData

nonisolated enum ProjectedCloudTransportProbe {
    struct Receipt: Codable {
        let formatVersion: Int
        let passed: Bool
        let environment: String
        let syntheticAssetBytes: Int64
        let automaticFetchCompletions: Int
        let initialProjectedRecords: Int
        let restartProjectedRecords: Int
        let replayProjectedRecords: Int
        let deliveredAssetBytes: Int64
        let engineFetchedRecords: Int
        let publishedAndReceived: Bool
    }

    static func runAndExit() -> Never {
        Task.detached {
            do {
                try requireDevelopmentSignature()
                try await DictationLibraryCloudProbe.run()
                let receipt = try await run()
                let path = ProcessInfo.processInfo.environment["MUMLA_TRANSPORT_PROBE_RECEIPT"] ?? "/tmp/mumla-transport-probe.json"
                try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: path), options: .atomic)
                print("Projected CloudKit transport probe complete; passed=\(receipt.passed) receipt: \(path)")
                exit(receipt.passed ? 0 : 1)
            } catch {
                let value = error as NSError
                print("Projected CloudKit transport probe failed: \(value.domain) \(value.code)")
                exit(1)
            }
        }
        dispatchMain()
    }

    static func requireDevelopmentSignature() throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw AudioArchiveError.invalidRecording }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let value = information as? [String: Any],
              let entitlements = value[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.developer.icloud-container-environment"] as? String == "Development"
        else { throw AudioArchiveError.invalidRecording }
    }

    private static func run() async throws -> Receipt {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WisprTransportProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = CKContainer(identifier: MumlaDataStore.cloudContainerIdentifier)
        let owner = try await cloud.userRecordID().recordName
        let database = cloud.privateCloudDatabase
        _ = try await database.save(CKRecordZone(zoneID: HistoryCloudSchema.zoneID))
        var fixtureIDs: [CKRecord.ID] = []
        var assetBytes: Int64 = 0
        do {
            for index in 0..<3 {
                let id = UUID()
                let data = try RealtimePCM16WAVFile.data(pcmData: Data(repeating: 0, count: 4 * 1_024 * 1_024), sampleRate: 48_000)
                let url = root.appendingPathComponent(id.uuidString + ".wav")
                try data.write(to: url, options: .atomic)
                let info = AudioRecordingInfo(id: id, createdAt: .now, providerRawValue: "synthetic-probe",
                    providerDisplayName: "Synthetic probe", deviceName: "Synthetic probe", source: "probe",
                    durationMilliseconds: nil, byteCount: data.count, sha256: AudioArchive.digest(data), fileType: .wav)
                let audio = try AudioCloudSchema.makeRecord(info: info, index: 0, fileURL: url)
                fixtureIDs.append(audio.recordID)
                _ = try await database.save(audio)
                let history = HistoryCloudSchema.makeRecord(from: .init(id: UUID(), text: "Synthetic transport fixture \(index)",
                    createdAt: .now, providerDisplayName: "Synthetic probe", deviceName: "Synthetic probe", audioRecordingID: id))
                fixtureIDs.append(history.recordID)
                _ = try await database.save(history)
                assetBytes += Int64(data.count)
            }
            let store = await MainActor.run { MumlaDataStore(directoryURL: root.appendingPathComponent("Store"), cloudSyncEnabled: false) }
            let container = await store.container
            let persistence = await AudioRecordingPersistence(container: container, archive: store.audioArchive)
            let first = AppCloudSyncCoordinator(container: container, directoryURL: root,
                audioPersistence: persistence, accountLease: AccountPartitionLease(ownerID: owner),
                onCloudDeletion: {}, onEncryptionReset: {}, onPersistenceError: nil)
            await first.start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while await first.transportProbeSnapshot().scheduledFetchCompletions == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            try await first.catchUpForArchive()
            let published = await store.record(text: "Synthetic publication probe")
            guard let published else { throw AudioArchiveError.transcriptNotSaved }
            fixtureIDs.append(HistoryCloudSchema.recordID(for: published))
            await first.uploadPendingChanges()
            try await first.catchUpForArchive()
            let a = await first.transportProbeSnapshot()
            await first.stopTransportProbe()
            let second = AppCloudSyncCoordinator(container: container, directoryURL: root,
                audioPersistence: persistence, accountLease: AccountPartitionLease(ownerID: owner),
                onCloudDeletion: {}, onEncryptionReset: {}, onPersistenceError: nil)
            await second.start()
            try await second.catchUpForArchive()
            let b = await second.transportProbeSnapshot()
            await second.stopTransportProbe()
            let token = root.appendingPathComponent("history-cloud-poll-token.data")
            if FileManager.default.fileExists(atPath: token.path) { try FileManager.default.removeItem(at: token) }
            let replay = AppCloudSyncCoordinator(container: container, directoryURL: root,
                audioPersistence: persistence, accountLease: AccountPartitionLease(ownerID: owner),
                onCloudDeletion: {}, onEncryptionReset: {}, onPersistenceError: nil)
            await replay.start()
            try await replay.catchUpForArchive()
            let c = await replay.transportProbeSnapshot()
            await replay.stopTransportProbe()
            let received = try await database.record(for: HistoryCloudSchema.recordID(for: published))
            let success = HistoryCloudSchema.value(from: received)?.id == published
            let bytes = a.deliveredAssetBytes + b.deliveredAssetBytes + c.deliveredAssetBytes
            let engineRecords = a.engineFetchedRecords + b.engineFetchedRecords + c.engineFetchedRecords
            let passed = a.scheduledFetchCompletions > 0 && a.projectedRecords >= 6
                && c.projectedRecords >= 6 && bytes == 0 && engineRecords == 0 && success
            for id in fixtureIDs { _ = try await database.deleteRecord(withID: id) }
            return Receipt(formatVersion: 1, passed: passed, environment: "Development", syntheticAssetBytes: assetBytes,
                automaticFetchCompletions: a.scheduledFetchCompletions, initialProjectedRecords: a.projectedRecords,
                restartProjectedRecords: b.projectedRecords, replayProjectedRecords: c.projectedRecords,
                deliveredAssetBytes: bytes, engineFetchedRecords: engineRecords, publishedAndReceived: success)
        } catch {
            for id in fixtureIDs { _ = try? await database.deleteRecord(withID: id) }
            throw error
        }
    }
}
#endif
