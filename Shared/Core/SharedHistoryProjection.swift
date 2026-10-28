import DictationLibrary
import Foundation
import SwiftData

actor SharedHistoryProjection {
    private let container: ModelContainer
    private var projected: [UUID: DictationArchiveEntry] = [:]
    private lazy var context: ModelContext = {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }()

    init(container: ModelContainer) { self.container = container }

    func insert(_ result: DictationResultVersion, deviceName: String, lease: AccountPartitionLease) throws {
        try Task.checkCancellation()
        guard lease.isActive else { throw LibraryAgentError.accountChanged }
        let id = result.id
        if let existing = try context.fetch(FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.id == id })).first {
            guard existing.text == result.text, existing.audioRecordingID == result.captureID else { throw AudioArchiveError.conflictingRecording }
            return
        }
        do {
            context.insert(HistoryEntry(id: result.id, text: result.text, createdAt: result.createdAt,
                providerDisplayName: TranscriptionProviderType.displayName(libraryModelID: result.model),
                deviceName: deviceName, audioRecordingID: result.captureID))
            guard lease.isActive else { throw LibraryAgentError.accountChanged }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func apply(_ entries: [DictationArchiveEntry], lease: AccountPartitionLease) throws {
        try Task.checkCancellation()
        guard lease.isActive else { throw LibraryAgentError.accountChanged }
        let changed = entries.filter { projected[$0.id] != $0 }
        guard !changed.isEmpty else { return }
        let history = try context.fetch(FetchDescriptor<HistoryEntry>())
        var byID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        let byCapture = Dictionary(grouping: history.compactMap { entry in entry.audioRecordingID.map { ($0, entry) } }, by: { $0.0 })
        var recordings = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AudioRecording>()).map { ($0.id, $0) })
        do {
            for entry in changed {
                let capture = entry.capture
                if let sha = capture.originalSHA256, let byteCount = capture.originalByteCount {
                    guard byteCount > 0, byteCount <= Int64(Int.max) else { throw AudioArchiveError.invalidRecording }
                    if let existing = recordings[capture.id] {
                        guard let info = existing.info, info.source.hasPrefix("unified/"),
                              info.sha256 == sha, Int64(info.byteCount) == byteCount else { throw AudioArchiveError.conflictingRecording }
                        if existing.uploaded != entry.published { existing.uploaded = entry.published }
                    } else {
                        let model = entry.results.first(where: { $0.kind == .providerOutput })?.model ?? capture.plan.effectiveModel
                        let info = AudioRecordingInfo(id: capture.id, createdAt: capture.startedAt,
                            providerRawValue: TranscriptionProviderType(libraryModelID: model)?.rawValue ?? model,
                            providerDisplayName: TranscriptionProviderType.displayName(libraryModelID: model),
                            deviceName: capture.source, source: "unified/" + capture.source, durationMilliseconds: nil,
                            byteCount: Int(byteCount), sha256: sha, fileType: .caf)
                        let recording = try AudioRecording(info: info, uploaded: entry.published)
                        context.insert(recording)
                        recordings[capture.id] = recording
                    }
                }
                let results = entry.results.filter { $0.kind != .failure && !$0.text.isEmpty }
                let resultIDs = Set(results.map(\.id))
                let texts = Set(results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
                var hiddenTexts = Set<String>()
                for (_, existing) in byCapture[capture.id] ?? [] where !resultIDs.contains(existing.id) {
                    let text = existing.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard texts.contains(text) else { continue }
                    if existing.isHidden { hiddenTexts.insert(text) }
                    context.delete(existing)
                    byID.removeValue(forKey: existing.id)
                }
                for result in results {
                    let hidden = hiddenTexts.contains(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let existing = byID[result.id] {
                        guard existing.text.trimmingCharacters(in: .whitespacesAndNewlines) == result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                              existing.audioRecordingID == capture.id else { throw AudioArchiveError.conflictingRecording }
                        if hidden { existing.isHidden = true }
                        if existing.text != result.text { existing.text = result.text }
                        continue
                    }
                    let row = HistoryEntry(id: result.id, text: result.text, createdAt: result.createdAt,
                        providerDisplayName: TranscriptionProviderType.displayName(libraryModelID: result.model),
                        deviceName: capture.source, audioRecordingID: capture.id)
                    row.isHidden = hidden
                    context.insert(row)
                    byID[row.id] = row
                }
            }
            try Task.checkCancellation()
            guard lease.isActive else { throw LibraryAgentError.accountChanged }
            if context.hasChanges { try context.save() }
            for entry in changed { projected[entry.id] = entry }
        } catch {
            context.rollback()
            throw error
        }
    }
}
