import DictationLibrary
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct DictationLibraryView: View {
    let library: UnifiedDictationLibrary
    let dataStore: MumlaDataStore
    let transcriber: AccessTranscriber
    let initialProfile: DictationProfile
    @State private var isRefreshing = false
    @State private var isExporting = false
    @State private var error: String?
    @State private var heldOriginal: URL?
    @State private var heldAssignment: HeldAssignment?

    private struct HeldAssignment {
        let id: UUID
        let session: DictationAccountSession
    }

    var body: some View {
        List {
            if dataStore.cloudDeletionNeedsDecision {
                Section { CloudLibraryRestorationView(dataStore: dataStore) }
            }
            DictationLibraryStatusSection(library: library)
            Section {
                NavigationLink {
                    DictationLibraryProfileView(library: library, dataStore: dataStore, profile: library.profile ?? initialProfile)
                } label: {
                    Label("Dictation Preferences", systemImage: "slider.horizontal.3")
                }
                .disabled(library.accountSession == nil)
                Button("Export Library", systemImage: "square.and.arrow.up") {
                    Task {
                        isExporting = true
                        defer { isExporting = false }
                        do { _ = try await library.exportArchive() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(isExporting || library.accountSession == nil)
                if isExporting { ProgressView("Preparing export…") }
                if let url = library.lastExportURL {
                    ShareLink("Share Latest Export", item: url)
                }
            }
            if !library.heldCaptures.isEmpty {
                Section("Unassigned Recordings") {
                    ForEach(library.heldCaptures, id: \.capture.id) { held in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(held.capture.startedAt, format: .dateTime.month().day().hour().minute())
                            HStack {
                                if let original = held.originalURL {
                                    Button("Listen", systemImage: "play.circle") { heldOriginal = original }
                                    ShareLink("Export Original", item: original)
                                }
                                Button("Assign to Current Account") {
                                    guard let session = library.accountSession else { return }
                                    heldAssignment = HeldAssignment(id: held.capture.id, session: session)
                                }
                                .disabled(library.accountSession == nil)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section("Recordings") {
                ForEach(library.entries) { entry in
                    NavigationLink {
                        DictationLibraryCaptureView(library: library, transcriber: transcriber, captureID: entry.id)
                    } label: {
                        DictationLibraryCaptureRow(entry: entry)
                    }
                }
                if library.entries.isEmpty {
                    Text(library.archiveRefreshedAt == nil ? "Recordings have not been loaded." : "No shared recordings.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle("Dictation Library")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(isRefreshing)
            if isRefreshing { ProgressView().controlSize(.small) }
        }
        .quickLookPreview($heldOriginal)
        .confirmationDialog("Assign this recording to the current iCloud account?", isPresented: Binding(
            get: { heldAssignment != nil }, set: { if !$0 { heldAssignment = nil } }
        ), titleVisibility: .visible) {
            if let assignment = heldAssignment {
                Button("Assign and Upload") {
                    Task {
                        do { try await library.reconcileHeldCapture(assignment.id, expectedAccount: assignment.session) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text("The original and its saved results will be shared with your other dictation apps.")
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await library.refresh()
        guard library.accountSession != nil else { return }
        do {
            try await library.refreshArchive()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct DictationLibraryStatusSection: View {
    @Bindable var library: UnifiedDictationLibrary
    @State private var releaseSession: DictationAccountSession?

    var body: some View {
        Section("Library Status") {
            LabeledContent("iCloud account", value: library.accountSession == nil ? "Unconfirmed" : "Confirmed")
            switch library.profileState {
            case .unverified:
                Label("Shared profile not verified", systemImage: "icloud")
            case .unavailable:
                Label("Shared profile unavailable", systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
            case .absent:
                Label("No shared profile yet", systemImage: "person.crop.circle.badge.plus")
            case .ready(let snapshot):
                Label(snapshot.profile.archiveEnabled ? "Recording sharing enabled" : "Recording sharing disabled", systemImage: snapshot.profile.archiveEnabled ? "checkmark.icloud" : "icloud.slash")
            }
            if let status = library.publicationStatus {
                LabeledContent("Waiting to upload", value: status.pendingCaptureCount.formatted())
                if status.heldCaptureCount > 0 {
                    Label("\(status.heldCaptureCount) recordings need ownership confirmation", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                }
                ForEach(status.failures, id: \.captureID) { failure in
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                ProgressView(value: Double(status.usedBytes), total: Double(status.capacityBytes)) {
                    Text("Local originals")
                } currentValueLabel: {
                    Text("\(status.usedBytes.formatted(.byteCount(style: .file))) of \(status.capacityBytes.formatted(.byteCount(style: .file)))")
                }
                Button("Free Uploaded Local Audio", systemImage: "internaldrive") {
                    releaseSession = library.accountSession
                }
                .disabled(status.releasableBytes == 0 || library.accountSession == nil)
            }
            LabeledContent("Independent backup", value: "Not verified here")
            if let refreshed = library.archiveRefreshedAt {
                LabeledContent("Library updated") { Text(refreshed, format: .dateTime.year().month().day().hour().minute()) }
            }
            #if os(macOS)
            Toggle("Keep all originals on this Mac", isOn: $library.archiveRoleEnabled)
                .onChange(of: library.archiveRoleEnabled) { _, enabled in
                    guard enabled else { return }
                    Task {
                        do { try await library.refreshArchive() }
                        catch { library.lastError = error.localizedDescription }
                    }
                }
            #endif
            if let error = library.lastError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .confirmationDialog("Free uploaded originals on this device?", isPresented: Binding(
            get: { releaseSession != nil }, set: { if !$0 { releaseSession = nil } }
        ), titleVisibility: .visible) {
            if let session = releaseSession {
                Button("Free Local Audio", role: .destructive) {
                    Task {
                        do { try await library.releaseUploadedOriginals(session: session) }
                        catch { library.lastError = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text("Only originals fully acknowledged by iCloud will be removed. An iCloud upload does not confirm an independent backup.")
        }
    }
}

private struct DictationLibraryCaptureRow: View {
    let entry: DictationArchiveEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.capture.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                Spacer()
                Text(DictationLibraryPresentation.sourceName(entry.capture.source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = entry.results.max(by: { $0.createdAt < $1.createdAt }) {
                Text(result.text.isEmpty ? "No text returned" : result.text).lineLimit(3)
                Text(DictationLibraryPresentation.kindName(result.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Original audio without a result").foregroundStyle(.secondary)
            }
            Label(entry.published ? "Saved in iCloud" : "Saved locally", systemImage: entry.published ? "checkmark.icloud" : "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct DictationLibraryCaptureView: View {
    let library: UnifiedDictationLibrary
    let transcriber: AccessTranscriber
    let captureID: UUID

    var body: some View {
        Group {
            if let entry = library.entries.first(where: { $0.id == captureID }) {
                DictationLibraryCaptureDetail(library: library, transcriber: transcriber, entry: entry)
            } else {
                ContentUnavailableView("Recording Unavailable", systemImage: "waveform", description: Text("Refresh the library for the current iCloud account."))
            }
        }
    }
}

private struct DictationLibraryCaptureDetail: View {
    let library: UnifiedDictationLibrary
    let transcriber: AccessTranscriber
    let entry: DictationArchiveEntry
    @State private var previewURL: URL?
    @State private var isWorking = false
    @State private var error: String?
    @State private var results: [DictationResultVersion] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Recorded") { Text(entry.capture.startedAt, format: .dateTime.year().month().day().hour().minute()) }
                LabeledContent("App", value: DictationLibraryPresentation.sourceName(entry.capture.source))
                LabeledContent("Context", value: entry.capture.plan.context.rawValue.capitalized)
                if entry.capture.interrupted {
                    Label("The recording was interrupted", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("Original Audio") {
                Button("Listen", systemImage: "play.circle") {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            let url = try await library.original(for: entry.id)
                            previewURL = url
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(isWorking)
                ShareLink(
                    item: DictationLibraryOriginalFile(captureID: entry.id, library: library),
                    preview: SharePreview("Recording")
                ) { Label("Export Audio", systemImage: "square.and.arrow.up") }
                Button("Transcribe Again", systemImage: "arrow.clockwise") {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do { try await library.retranscribe(entry.id, using: transcriber) }
                        catch { self.error = TranscriptionFailureMessage.text(for: error, allowance: transcriber.access.state) }
                    }
                }
                .disabled(isWorking)
                if isWorking { ProgressView() }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Result Versions") {
                ForEach(results) { result in
                    DictationLibraryResultRow(result: result)
                }
            }
        }
        .navigationTitle("Recording")
        .quickLookPreview($previewURL)
        .onChange(of: entry.results, initial: true) { _, value in
            results = value.sorted { $0.createdAt > $1.createdAt }
        }
    }
}

private struct DictationLibraryResultRow: View {
    let result: DictationResultVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DictationLibraryPresentation.kindName(result.kind)).font(.headline)
            Text(result.text.isEmpty ? "No text returned" : result.text).textSelection(.enabled)
            Text(result.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            if result.contextWasUsed { Label("Context used", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}

private enum DictationLibraryPresentation {
    static func kindName(_ kind: DictationResultKind) -> String {
        switch kind {
        case .providerOutput: "Transcript"
        case .cleanup: "Cleaned Transcript"
        case .contextualOutput: "Contextual Output"
        case .answer: "AI Answer"
        case .failure: "Dictation Failed"
        }
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "wisprclone", "emileberhard.WisprClone", "emileberhard.WisprClone.ios": "Mumla"
        case "dev.tuist.agentty.iOS", "dev.tuist.agentty.iOS.dev", "dev.tuist.agentty.iOS.exp": "AgenTTY"
        case "remotecoder": "RemoteCoder"
        default: source
        }
    }
}

private nonisolated struct DictationLibraryOriginalFile: Transferable {
    let captureID: UUID
    let library: UnifiedDictationLibrary

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .audio) { file in
            SentTransferredFile(try await file.library.original(for: file.captureID))
        }
    }
}
