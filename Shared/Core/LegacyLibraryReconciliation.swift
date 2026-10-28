import Foundation
import SwiftData

nonisolated struct LegacyLibraryReport: Codable, Sendable {
    var historyCount = 0
    var duplicateHistoryCount = 0
    var uniqueHistoryIDs: [UUID] = []
    var vocabularyCount = 0
    var changedVocabularyCount = 0
    var recordingCount = 0
    var duplicateRecordingCount = 0
    var uniqueRecordingIDs: [UUID] = []
    var conflictingIDs: [String] = []

    mutating func append(_ other: Self) {
        historyCount += other.historyCount
        duplicateHistoryCount += other.duplicateHistoryCount
        uniqueHistoryIDs += other.uniqueHistoryIDs
        vocabularyCount += other.vocabularyCount
        changedVocabularyCount += other.changedVocabularyCount
        recordingCount += other.recordingCount
        duplicateRecordingCount += other.duplicateRecordingCount
        uniqueRecordingIDs += other.uniqueRecordingIDs
        conflictingIDs += other.conflictingIDs
    }
}

@MainActor
struct LegacyLibraryReconciliation {
    let history: [HistoryEntry]
    let vocabulary: [VocabularyEntry]
    let recordings: [AudioRecordingInfo]
    let keys: [String]
    let report: LegacyLibraryReport

    nonisolated private struct HistoryIdentity: Hashable {
        let text: String
        let createdAt: Date
        let audioRecordingID: UUID?
        init(_ entry: HistoryEntry) {
            text = entry.text
            createdAt = entry.createdAt
            audioRecordingID = entry.audioRecordingID
        }
    }

    init(source: ModelContext, destination: ModelContext, ownership: LegacyDataOwnership, ownerID: String) throws {
        let sourceRecordings = try source.fetch(FetchDescriptor<AudioRecording>()).map { recording in
            guard let info = recording.info else { throw AudioArchiveError.invalidRecording }
            return info
        }
        let sharedIDs = Set(sourceRecordings.filter { $0.source.hasPrefix("unified/") }.map(\.id))
        let sourceHistory = try source.fetch(FetchDescriptor<HistoryEntry>()).filter {
            !($0.audioRecordingID.map(sharedIDs.contains) ?? false)
                && ownership.needsReconciliation("history-" + $0.id.uuidString, currentOwner: ownerID)
        }
        let sourceVocabulary = try source.fetch(FetchDescriptor<VocabularyEntry>()).filter {
            ownership.needsReconciliation($0.id + "-" + String($0.modifiedAt.timeIntervalSince1970), currentOwner: ownerID)
        }
        let eligibleRecordings = sourceRecordings.filter {
            !sharedIDs.contains($0.id) && ownership.needsReconciliation("audio-" + $0.id.uuidString, currentOwner: ownerID)
        }
        let existingHistory = try destination.fetch(FetchDescriptor<HistoryEntry>())
        let historyByID = Dictionary(uniqueKeysWithValues: existingHistory.map { ($0.id, $0) })
        var identities = Set(existingHistory.map(HistoryIdentity.init))
        let vocabularyByID = Dictionary(uniqueKeysWithValues: try destination.fetch(FetchDescriptor<VocabularyEntry>()).map { ($0.id, $0) })
        let audioByID = Dictionary(uniqueKeysWithValues: try destination.fetch(FetchDescriptor<AudioRecording>()).map { recording in
            guard let info = recording.info else { throw AudioArchiveError.invalidRecording }
            return (info.id, info)
        })
        var report = LegacyLibraryReport()
        var history: [HistoryEntry] = []
        var vocabulary: [VocabularyEntry] = []
        var recordings: [AudioRecordingInfo] = []
        for entry in sourceHistory.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            report.historyCount += 1
            if let existing = historyByID[entry.id] {
                if HistoryIdentity(existing) != HistoryIdentity(entry) { report.conflictingIDs.append("history-" + entry.id.uuidString) }
                else { report.duplicateHistoryCount += 1 }
            } else if !identities.insert(HistoryIdentity(entry)).inserted {
                report.duplicateHistoryCount += 1
            } else {
                history.append(entry)
                report.uniqueHistoryIDs.append(entry.id)
            }
        }
        for entry in sourceVocabulary {
            report.vocabularyCount += 1
            if let existing = vocabularyByID[entry.id], entry.modifiedAt <= existing.modifiedAt { continue }
            vocabulary.append(entry)
            report.changedVocabularyCount += 1
        }
        for info in eligibleRecordings {
            report.recordingCount += 1
            if let existing = audioByID[info.id] {
                if existing.sha256 != info.sha256 || existing.byteCount != info.byteCount {
                    report.conflictingIDs.append("audio-" + info.id.uuidString)
                } else { report.duplicateRecordingCount += 1 }
            } else {
                recordings.append(info)
                report.uniqueRecordingIDs.append(info.id)
            }
        }
        self.history = history
        self.vocabulary = vocabulary
        self.recordings = recordings
        keys = sourceHistory.map { "history-" + $0.id.uuidString }
            + sourceVocabulary.map { $0.id + "-" + String($0.modifiedAt.timeIntervalSince1970) }
            + eligibleRecordings.map { "audio-" + $0.id.uuidString }
        self.report = report
    }
}
