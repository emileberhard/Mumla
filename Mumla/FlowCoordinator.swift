import DictationLibrary
import AVFoundation
import AppKit
import GrantKit
import os
import SwiftUI
import Observation
import ServiceManagement
import SpeechKit

enum SettingsTab: Hashable {
    case general
    case dictionary
    case history
    case recovery
}

@MainActor
@Observable
final class FlowCoordinator {
    static let shared = FlowCoordinator()
    private static let syncedPreferenceKeys = [SharedPreferenceKey.dictationLanguages]

    private let preferenceSync = CloudPreferenceStore()
    let access = MumlaAccess()
    var transcriber: AccessTranscriber { AccessTranscriber(access: access) }

    // MARK: - State
    var state: FlowState = .idle {
        didSet {
            guard state != oldValue else { return }
            keyboardMonitor.setRecordingKeyHandlingEnabled(state == .recording)
            AppDiagnostics.info(
                "Flow state changed",
                category: "state",
                metadata: [
                    "from": String(describing: oldValue),
                    "to": String(describing: state),
                ]
            )
        }
    }
    var transcript = ""
    var settingsTab: SettingsTab = .general
    var recoveryStatusMessage = ""
    var retryingRecoveryRecordingID: UUID?

    /// Ordered ISO 639-1 codes; defaults to the system languages until the
    /// user edits the list in Settings.
    var dictationLanguages: [String] {
        didSet {
            preferenceSync.set(DictationLanguages.encode(dictationLanguages), forKey: SharedPreferenceKey.dictationLanguages)
        }
    }

    var spokenLanguagesOwner: SpokenLanguagesOwner {
        dataStore.library?.spokenLanguagesOwner(iCloudSignedOut: access.state.isICloudSignedOut) ?? .local
    }

    var spokenLanguages: [String] {
        spokenLanguagesOwner.languages(local: dictationLanguages)
    }

    func addDictationLanguage(_ code: String) {
        guard !spokenLanguages.contains(code) else { return }
        setSpokenLanguages(spokenLanguages + [code])
    }

    func removeDictationLanguage(_ code: String) {
        setSpokenLanguages(spokenLanguages.filter { $0 != code })
    }

    private func setSpokenLanguages(_ languages: [String]) {
        let edit: SpokenLanguagesEdit
        do {
            edit = try dataStore.library?.editSpokenLanguages(languages, iCloudSignedOut: access.state.isICloudSignedOut)
                ?? SpokenLanguagesOwner.local.edit(languages)
        } catch {
            AppDiagnostics.error("Spoken languages edit failed", category: "dictation_library", error: error)
            return
        }
        if case .local(let languages) = edit { dictationLanguages = languages }
    }

    var autoSend: Bool {
        didSet {
            UserDefaults.standard.set(autoSend, forKey: "autoSend")
        }
    }

    var keyboardShortcutMode: KeyboardShortcutMode {
        didSet {
            UserDefaults.standard.set(keyboardShortcutMode.rawValue, forKey: "keyboardShortcutMode")
            keyboardMonitor.shortcutMode = keyboardShortcutMode
            AppDiagnostics.info(
                "Keyboard shortcut mode changed",
                category: "input",
                metadata: ["mode": keyboardShortcutMode.rawValue]
            )
        }
    }

    var inputMonitoringPermissionState: InputMonitoringPermissionState = .unknown
    var accessibilityPermissionGranted = SystemPermission.accessibility.isGranted

    enum ShortcutStatus {
        case waitingForPermissions
        case running
        case needsRestart
        case unavailable
    }

    private(set) var shortcutStatus: ShortcutStatus = .waitingForPermissions
    private let inputMonitoringGrantedAtLaunch = SystemPermission.inputMonitoring.isGranted

    var launchAtLogin: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to \(newValue ? "enable" : "disable") launch at login: \(DiagnosticError(error).metadata)")
            }
        }
    }

    var customVocabulary: [String] {
        dataStore.vocabularyTerms
    }

    func addVocabularyTerm(_ text: String) {
        dataStore.addVocabularyTerm(text)
    }

    func removeVocabularyTerm(_ entry: VocabularyEntry) {
        dataStore.removeVocabularyTerm(entry)
    }

    func updateVocabularyTerm(_ entry: VocabularyEntry, to newValue: String) {
        dataStore.updateVocabularyTerm(entry, to: newValue)
    }

    func replaceVocabulary(with terms: [String]) {
        dataStore.replaceVocabulary(with: terms)
    }

    @ObservationIgnored private lazy var recoveryStore = RecordingRecoveryStore(dataStore: dataStore)
    let dataStore = MumlaDataStore(onPersistenceError: { error in
        AppDiagnostics.error(
            "App data persistence failed",
            category: "persistence",
            error: error
        )
    })
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?
    private let keyboardMonitor = KeyboardMonitor()

    var isLockedRecording: Bool { keyboardMonitor.inToggleMode }

    private(set) var recordingStartTime: Date?
    private(set) var recordingLimit = TimeInterval(AccessGrant.progressiveAudioSeconds)

    var recordingDeadline: Date? {
        recordingStartTime?.addingTimeInterval(recordingLimit)
    }

    private var transcriptionTask: Task<Void, Never>?
    private var realtimeDictationController: RealtimeDictationController?
    private var realtimeStartTask: Task<Void, Never>?
    private var realtimeCaptureID: UUID? {
        didSet { recordingStopTask?.cancel() }
    }
    @ObservationIgnored private var recordingStopTask: Task<Void, Never>?
    @ObservationIgnored private var errorDismissTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard

        self.dictationLanguages = DictationLanguages.decode(preferenceSync.string(forKey: SharedPreferenceKey.dictationLanguages))
            ?? DictationLanguages.systemDefault()
        self.autoSend = defaults.bool(forKey: "autoSend")
        let keyboardShortcutModeRaw = defaults.string(forKey: "keyboardShortcutMode") ?? KeyboardShortcutMode.holdToTalk.rawValue
        self.keyboardShortcutMode = KeyboardShortcutMode(rawValue: keyboardShortcutModeRaw) ?? .holdToTalk
        let inputStatus = keyboardMonitor.inputMonitoringStatus()
        self.inputMonitoringPermissionState = inputStatus.state

        migrateLegacyVocabulary()
        KeychainStore.deleteRetiredAPIKeys()
        AppDiagnostics.setTag("provider", value: TranscriptionProviderType.dictation.rawValue)

        accountObserver = NotificationCenter.default.addObserver(forName: .mumlaAccountInvalidated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }

        preferenceSync.observeRemoteChanges { [weak self] changedKeys in
            self?.syncFromCloud(changedKeys: changedKeys)
        }
        preferenceSync.pushCurrentValues(keys: Self.syncedPreferenceKeys)

        Task { await importLegacyAudio() }
        setupKeyboardMonitor()
        observePermissions()
        AppDiagnostics.info(
            "FlowCoordinator initialized",
            category: "app",
            metadata: [
                "auto_send": autoSend.description,
                "keyboard_shortcut_mode": keyboardShortcutMode.rawValue,
                "language_hints": dictationLanguages.joined(separator: ","),
            ]
        )

        Task {
            FloatingWindowController.shared.showWindow()
            OnboardingController.shared.showIfNeeded(coordinator: self)
        }
    }

    private func syncFromCloud(changedKeys: Set<String>?) {
        func shouldSync(_ key: String) -> Bool {
            changedKeys?.contains(key) ?? true
        }

        if shouldSync(SharedPreferenceKey.dictationLanguages),
           let synced = DictationLanguages.decode(preferenceSync.string(forKey: SharedPreferenceKey.dictationLanguages)) {
            dictationLanguages = synced
        }
        if shouldSync(SharedPreferenceKey.customVocabulary) {
            migrateLegacyVocabulary()
        }
    }

    private func migrateLegacyVocabulary() {
        dataStore.importLegacyVocabulary(
            preferenceSync.legacyStringValues(forKey: SharedPreferenceKey.customVocabulary)
        )
    }

    // MARK: - Setup
    
    private func setupKeyboardMonitor() {
        keyboardMonitor.shortcutMode = keyboardShortcutMode
        keyboardMonitor.onGlobePressed = { [weak self] in
            self?.startRecording()
        }
        keyboardMonitor.onGlobeReleased = { [weak self] in
            self?.stopRecording()
        }
        keyboardMonitor.onEscapePressed = { [weak self] in
            self?.cancel()
        }
        // No prompt at launch: the onboarding window owns permission
        // requests, so a fresh install is not greeted by raw system dialogs.
        refreshInputMonitoringPermission(prompt: false)
        startKeyboardMonitorIfPermitted()
    }

    /// Creates the global hotkey event tap only once the permissions it needs
    /// are already granted. The tap is an active (event-consuming) tap so it
    /// can swallow the Fn/globe key, and active taps require Accessibility;
    /// creating one while untrusted makes macOS post its own "Accessibility
    /// Access" prompt — the raw dialog the onboarding window replaces. Gating
    /// on both grants guarantees `tapCreate` never triggers a system prompt.
    private func startKeyboardMonitorIfPermitted() {
        guard !keyboardMonitor.isRunning else { return }
        guard inputMonitoringPermissionState == .granted,
              SystemPermission.accessibility.isGranted
        else {
            shortcutStatus = .waitingForPermissions
            return
        }
        if keyboardMonitor.start() {
            shortcutStatus = .running
        } else {
            shortcutStatus = inputMonitoringGrantedAtLaunch ? .unavailable : .needsRestart
        }
    }

    func refreshInputMonitoringPermission(prompt: Bool) {
        _ = keyboardMonitor.requestInputMonitoringPermission(prompt: prompt)
        let status = keyboardMonitor.inputMonitoringStatus()
        inputMonitoringPermissionState = status.state
    }

    /// Keeps permission state live and starts the hotkey event tap as soon
    /// as the required grants land, so a grant made while the app runs takes
    /// effect without a relaunch.
    private func observePermissions() {
        Task {
            for await _ in PermissionMonitor.updates(for: .inputMonitoring) {
                handlePermissionChange()
            }
        }
        Task {
            for await granted in PermissionMonitor.updates(for: .accessibility) {
                accessibilityPermissionGranted = granted
                handlePermissionChange()
            }
        }
    }

    private func handlePermissionChange() {
        refreshInputMonitoringPermission(prompt: false)
        startKeyboardMonitorIfPermitted()
    }

    func guideInputMonitoringAccess() async {
        await PermissionGuide.request(.inputMonitoring)
        refreshInputMonitoringPermission(prompt: false)
    }

    func guideAccessibilityAccess() async {
        await PermissionGuide.request(.accessibility)
        accessibilityPermissionGranted = SystemPermission.accessibility.isGranted
    }

    // MARK: - Recovery

    func importLegacyAudio() async {
        do { try await recoveryStore.importLegacyRecordings() }
        catch {
            recoveryStatusMessage = "Audio import failed: \(error.localizedDescription)"
            AppDiagnostics.error("Legacy audio import failed", category: "recovery", error: error)
        }
    }

    func retryRecoverableTranscription(id: UUID) {
        guard retryingRecoveryRecordingID == nil else { return }

        retryingRecoveryRecordingID = id
        recoveryStatusMessage = "Retrying transcription..."

        Task {
            do {
                if try dataStore.recordingInfo(for: id).source.hasPrefix("unified/"), let library = dataStore.library {
                    try await library.refreshArchive()
                    try await library.retranscribe(id, using: transcriber)
                    recoveryStatusMessage = "A new result was saved in the shared library."
                    retryingRecoveryRecordingID = nil
                    return
                }
                guard let recording = try recoveryStore.recording(with: id) else {
                    throw AudioArchiveError.invalidRecording
                }
                let text = try await transcribeRecoverableRecording(recording)
                dataStore.record(text: text, audioRecordingID: recording.id)
                recoveryStatusMessage = "Recovered transcript updated."
                AppDiagnostics.info(
                    "Recoverable recording transcription retry succeeded",
                    category: "recovery",
                    metadata: [
                        "recording_id": recording.id.uuidString,
                        "length": String(text.count),
                    ]
                )
            } catch {
                recoveryStatusMessage = TranscriptionFailureMessage.text(for: error, allowance: access.state)
                AppDiagnostics.error(
                    "Recoverable recording transcription retry failed",
                    category: "recovery",
                    metadata: ["recording_id": id.uuidString],
                    error: error
                )
            }

            retryingRecoveryRecordingID = nil
        }
    }

    private func transcribeRecoverableRecording(
        _ recording: RecoverableRecording
    ) async throws -> String {
        let text = try await transcribeAudio(
            wavData: dataStore.providerWAV(for: recording.id),
            recordingID: recording.id
        )
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecoveryTranscriptionError.emptyRecoveredTranscript
        }
        return text
    }

    /// Returns nil when the fallback handled the recording (pasted or
    /// intentionally discarded), or a user-facing failure message otherwise.
    private func pasteRecoveredRealtimeTranscript(
        from recording: RecoverableRecording,
        durationMilliseconds: String,
        reason: String,
        diagnosticsSessionID: String? = nil
    ) async -> String? {
        AppDiagnostics.info(
            "Realtime fallback transcription started",
            category: "recovery",
            metadata: [
                "recording_id": recording.id.uuidString,
                "provider": recording.providerRawValue,
                "duration_ms": durationMilliseconds,
                "reason": reason,
                "realtime_session_id": diagnosticsSessionID ?? recording.diagnosticsSessionID ?? "none",
                "audio_file": recording.audioFileName,
                "audio_bytes": String(recording.audioByteCount),
            ].merging(AppDiagnostics.networkPathMetadata()) { _, new in new }
        )

        do {
            let text = try await transcribeRecoverableRecording(recording)
            guard !Task.isCancelled else { return nil }
            AppDiagnostics.info(
                "Realtime fallback transcription succeeded",
                category: "recovery",
                metadata: [
                    "recording_id": recording.id.uuidString,
                    "duration_ms": durationMilliseconds,
                    "length": String(text.count),
                    "reason": reason,
                    "realtime_session_id": diagnosticsSessionID ?? recording.diagnosticsSessionID ?? "none",
                    "audio_file": recording.audioFileName,
                    "audio_bytes": String(recording.audioByteCount),
                ].merging(AppDiagnostics.networkPathMetadata()) { _, new in new }
            )

            guard TranscriptSoundEvents.containsSpeech(text) else {
                AppDiagnostics.info(
                    "Recovered transcript discarded as non-speech",
                    category: "recovery",
                    metadata: [
                        "recording_id": recording.id.uuidString,
                        "length": String(text.count),
                    ]
                )
                state = .idle
                keyboardMonitor.resetToggleMode()
                return nil
            }

            dataStore.record(text: text, audioRecordingID: recording.id)
            state = .success
            transcript = text
            paste(text)

            try? await Task.sleep(for: .seconds(0.8))
            if state == .success {
                state = .idle
                keyboardMonitor.resetToggleMode()
            }
            return nil
        } catch {
            if Task.isCancelled || error is CancellationError {
                // User cancelled mid-fallback; the recording stays available
                // in the recovery list for a manual retry.
                return nil
            }
            let metadata = [
                "recording_id": recording.id.uuidString,
                "provider": recording.providerRawValue,
                "duration_ms": durationMilliseconds,
                "reason": reason,
                "realtime_session_id": diagnosticsSessionID ?? recording.diagnosticsSessionID ?? "none",
                "audio_file": recording.audioFileName,
                "audio_bytes": String(recording.audioByteCount),
            ]
            if case RecoveryTranscriptionError.emptyRecoveredTranscript = error {
                // Expected outcome for silence-only audio (HTTP 200, empty
                // text): return to idle quietly, matching iOS, instead of
                // flashing an error at someone who dictated nothing.
                AppDiagnostics.warning(
                    "Realtime fallback produced empty transcript",
                    category: "recovery",
                    metadata: metadata
                )
                state = .idle
                keyboardMonitor.resetToggleMode()
                return nil
            }
            AppDiagnostics.error(
                "Realtime fallback transcription failed",
                category: "recovery",
                metadata: metadata,
                error: error
            )
            return TranscriptionFailureMessage.text(for: error, allowance: access.state)
        }
    }

    private func saveRecoverableRecording(
        from originalAudio: Result<URL, any Error>,
        source: RecordingRecoverySource,
        durationMilliseconds: Int?,
        diagnosticsSessionID: String? = nil
    ) async -> RecoverableRecording? {
        do {
            return try await recoveryStore.saveRecording(
                originalAudio,
                source: source,
                durationMilliseconds: durationMilliseconds,
                diagnosticsSessionID: diagnosticsSessionID
            )
        } catch {
            AppDiagnostics.error(
                "Failed to save recoverable recording",
                category: "recovery",
                metadata: [
                    "source": source.rawValue,
                    "realtime_session_id": diagnosticsSessionID ?? "none",
                ],
                error: error
            )
            recoveryStatusMessage = "Audio could not be archived: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Recording
    
    func startRecording() {
        // Match iOS: no new session while one is recording or still stopping.
        // Escape (or a quick Fn tap) cancels an in-flight stop instead.
        switch state {
        case .idle, .success, .error:
            break
        case .recording, .processing:
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        AppDiagnostics.info(
            "Start recording requested",
            category: "recording",
            metadata: ["auto_send": autoSend.description]
        )

        FloatingWindowController.shared.showWindow()
        startRealtimeRecording()
    }

    func stopRecording() {
        guard state == .recording else { return }
        realtimeCaptureID = nil
        AppDiagnostics.info(
            "Stop realtime recording requested",
            category: "recording",
            metadata: ["duration_ms": currentRecordingDurationMilliseconds()]
        )
        stopRealtimeRecording()
    }

    private func stopRecording(captureID: UUID) {
        guard realtimeCaptureID == captureID else { return }
        keyboardMonitor.resetToggleMode()
        stopRecording()
    }

    func cancel() {
        AppDiagnostics.info("Cancel realtime recording requested", category: "recording")
        realtimeCaptureID = nil
        realtimeDictationController?.prepareAudioForArchiving()
        realtimeStartTask?.cancel()
        realtimeStartTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        let controller = realtimeDictationController
        let wasRecording = state == .recording
        realtimeDictationController = nil
        let duration = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1_000) }
        recordingStartTime = nil
        state = .idle
        keyboardMonitor.resetToggleMode()
        Task {
            guard wasRecording else { return }
            if let originalAudio = await controller?.cancelAndRecoverAudio() {
                _ = await saveRecoverableRecording(
                    from: originalAudio, source: .realtime,
                    durationMilliseconds: duration
                )
            }
        }
    }

    // MARK: - Transcription
    
    private func transcribeAudio(
        wavData: Data,
        recordingID: UUID?
    ) async throws -> String {
        let plan = recordingID.flatMap { dataStore.library?.plan(for: $0) }
        if let recordingID, plan != nil { try await dataStore.library?.validateProviderCapture(recordingID) }
        let result = try await transcriber.transcribe(
            wav: wavData,
            languageHints: plan?.languages ?? dictationLanguages,
            customVocabulary: plan?.dictionary ?? customVocabulary
        )
        guard !Task.isCancelled else { throw CancellationError() }

        if let recordingID, let library = dataStore.library, plan != nil {
            try await library.recordProviderOutput(result.text, captureID: recordingID, model: TranscriptionProviderType.dictation.batchResultModelID)
        }
        guard !Task.isCancelled else { throw CancellationError() }

        var text = result.text
        if let lastChar = text.last, ".?!".contains(lastChar) {
            text.append(" ")
        }
        return text
    }

    private func showError(_ message: String) {
        AppDiagnostics.error("Showing error state", category: "state")
        recordingStartTime = nil
        AudioAnalyzer.resetLevel()
        state = .error(message: message)
        errorDismissTask?.cancel()
        errorDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if case .error = state {
                state = .idle
            }
        }
    }

    // MARK: - Clipboard Logic

    private func paste(_ text: String, triggerAutoSend: Bool = true) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppDiagnostics.info(
            "Clipboard paste requested",
            category: "clipboard",
            metadata: [
                "length": String(text.count),
                "auto_send": (triggerAutoSend && autoSend).description,
            ]
        )

        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        cmdDown?.flags = .maskCommand
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        if triggerAutoSend && autoSend {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                pressEnter()
            }
        }
    }

    private func pressEnter() {
        let source = CGEventSource(stateID: .hidSystemState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        enterDown?.flags = []
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        enterUp?.flags = []
        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }

    private func startRealtimeRecording() {
        if let failure = access.state.blockingFailure {
            showError(TranscriptionFailureMessage.text(for: failure, allowance: access.state))
            return
        }
        let vocabulary = customVocabulary
        let languages = dictationLanguages
        let partition = dataStore.partitionID
        let captureID = UUID()
        realtimeCaptureID = captureID
        let access = access
        let grant = Task { try await access.grant(maximumAudioSeconds: AccessGrant.progressiveAudioSeconds) }
        let controller = RealtimeDictationController(
            makeProviderConfiguration: { [weak self] original in
                let plan = original.dictationPlan
                return RealtimeDictationProviderConfiguration(
                    grant: grant,
                    customVocabulary: plan?.dictionary ?? vocabulary,
                    languageHints: plan?.languages ?? languages,
                    onAudioLimitReached: { Task { @MainActor in self?.stopRecording(captureID: captureID) } }
                )
            },
            makeOriginalAudio: { [dataStore] in
                guard dataStore.partitionID == partition else { throw CancellationError() }
                return try await dataStore.makeOriginalAudioWriter(context: .prose)
            }
        )
        let diagnosticsSessionID = controller.diagnosticsSessionID
        realtimeDictationController = controller
        recordingStartTime = Date()
        recordingLimit = TimeInterval(AccessGrant.progressiveAudioSeconds)
        scheduleRecordingStop(captureID: captureID)
        state = .recording
        AppDiagnostics.info(
            "Starting realtime recording",
            category: "realtime",
            metadata: [
                "realtime_session_id": diagnosticsSessionID,
            ]
        )

        Task { [weak self] in
            switch await grant.result {
            case .success(let reserved) where self?.realtimeCaptureID == captureID:
                self?.recordingLimit = reserved.audioLimit
                self?.scheduleRecordingStop(captureID: captureID)
            case .failure(let error) where error is AccessFailure:
                self?.stopRecording(captureID: captureID)
            default:
                break
            }
        }
        realtimeStartTask?.cancel()
        realtimeStartTask = Task(name: "RealtimeDictation") { [weak self, controller] in
            do {
                try await controller.start()
            } catch {
                guard let self else { return }
                guard !Task.isCancelled else {
                    await controller.cancel()
                    return
                }
                AppDiagnostics.error(
                    "Failed to start realtime dictation",
                    category: "realtime",
                    metadata: [
                        "realtime_session_id": controller.diagnosticsSessionID,
                    ],
                    error: error
                )
                if self.realtimeDictationController === controller {
                    self.realtimeDictationController = nil
                }
                if self.realtimeCaptureID == captureID {
                    self.realtimeCaptureID = nil
                }
                self.recordingStartTime = nil
                self.keyboardMonitor.resetToggleMode()
                grant.cancel()
                self.showError(TranscriptionFailureMessage.text(for: error, allowance: self.access.state))
            }
        }
    }

    private func scheduleRecordingStop(captureID: UUID) {
        recordingStopTask?.cancel()
        guard let deadline = recordingDeadline else { return }
        recordingStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.stopRecording(captureID: captureID)
        }
    }

    private func stopRealtimeRecording() {
        realtimeDictationController?.prepareAudioForArchiving()
        realtimeStartTask?.cancel()
        realtimeStartTask = nil
        let durationMilliseconds = currentRecordingDurationMilliseconds()
        let diagnosticsSessionID = realtimeDictationController?.diagnosticsSessionID
        AppDiagnostics.info(
            "Stopping realtime recording",
            category: "realtime",
            metadata: [
                "duration_ms": durationMilliseconds,
                "realtime_session_id": diagnosticsSessionID ?? "none",
            ]
        )
        guard let controller = realtimeDictationController else {
            AppDiagnostics.warning(
                "No realtime controller available when stopping",
                category: "realtime",
                metadata: [
                    "realtime_session_id": diagnosticsSessionID ?? "none",
                ]
            )
            state = .idle
            keyboardMonitor.resetToggleMode()
            return
        }

        state = .processing
        transcriptionTask = Task(name: "RealtimeStop") { [weak self, controller] in
            let result = await controller.stop()
            guard let self else { return }

            if self.realtimeDictationController === controller {
                self.realtimeDictationController = nil
                self.recordingStartTime = nil
            }

            var recoverableRecording: RecoverableRecording?
            if let originalAudio = result.originalAudio {
                recoverableRecording = await self.saveRecoverableRecording(
                    from: originalAudio,
                    source: .realtime,
                    durationMilliseconds: Int(durationMilliseconds),
                    diagnosticsSessionID: result.diagnosticsSessionID
                )
            }

            guard !Task.isCancelled else { return }
            let text = result.text
            guard let text, !text.isEmpty else {
                let fallbackReason = result.fallbackReason ?? "missing_realtime_committed_transcript"
                AppDiagnostics.warning(
                    "Realtime recording produced no pasteable transcript",
                    category: "realtime",
                    metadata: [
                        "duration_ms": durationMilliseconds,
                        "recovery_recording_id": recoverableRecording?.id.uuidString ?? "none",
                        "fallback_reason": fallbackReason,
                        "realtime_session_id": result.diagnosticsSessionID,
                    ]
                )
                // Debounce short taps: skip the batch fallback and the error
                // flash, matching the 0.5 s guards on both batch paths.
                if let durationMillisecondsValue = Int(durationMilliseconds), durationMillisecondsValue < 500 {
                    AppDiagnostics.info(
                        "Realtime recording discarded as too short",
                        category: "realtime",
                        metadata: [
                            "duration_ms": durationMilliseconds,
                            "recovery_recording_id": recoverableRecording?.id.uuidString ?? "none",
                        ]
                    )
                    self.state = .idle
                    self.keyboardMonitor.resetToggleMode()
                    return
                }
                guard let failure = result.failure else {
                    self.state = .idle
                    self.keyboardMonitor.resetToggleMode()
                    return
                }
                switch TranscriptionRecovery(after: failure) {
                case .resendArchived:
                    guard let recoverableRecording else { break }
                    if let failureMessage = await self.pasteRecoveredRealtimeTranscript(
                        from: recoverableRecording,
                        durationMilliseconds: durationMilliseconds,
                        reason: fallbackReason,
                        diagnosticsSessionID: result.diagnosticsSessionID
                    ) {
                        self.showError(failureMessage)
                    }
                    return
                case .canceled:
                    self.state = .idle
                    self.keyboardMonitor.resetToggleMode()
                    return
                case .refused, .keepForRetry:
                    break
                }
                self.showError(TranscriptionFailureMessage.text(for: failure, allowance: self.access.state))
                return
            }

            if let recordingID = recoverableRecording?.id, let library = self.dataStore.library,
               library.plan(for: recordingID) != nil {
                do { try await library.recordProviderOutput(text, captureID: recordingID, model: TranscriptionProviderType.dictation.libraryModelID) }
                catch {
                    self.recoveryStatusMessage = error.localizedDescription
                    self.state = .idle
                    self.keyboardMonitor.resetToggleMode()
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self.dataStore.record(text: text, audioRecordingID: recoverableRecording?.id)
            AppDiagnostics.info(
                "Pasting buffered realtime transcript",
                category: "realtime",
                metadata: [
                    "duration_ms": durationMilliseconds,
                    "length": String(text.count),
                    "recovery_recording_id": recoverableRecording?.id.uuidString ?? "none",
                    "realtime_session_id": result.diagnosticsSessionID,
                ]
            )
            self.state = .success
            self.transcript = text
            self.paste(text)

            try? await Task.sleep(for: .seconds(0.8))
            if self.state == .success {
                self.state = .idle
                self.keyboardMonitor.resetToggleMode()
            }
        }
    }

    private func currentRecordingDurationMilliseconds() -> String {
        guard let recordingStartTime else { return "unknown" }
        return String(max(0, Int(Date().timeIntervalSince(recordingStartTime) * 1_000)))
    }

    func openDiagnosticsLogsFolder() {
        AppDiagnostics.openLogsFolder()
    }

    func copyDiagnostics() {
        AppDiagnostics.copyRecentDiagnostics()
    }

}

enum RecoveryTranscriptionError: LocalizedError {
    case emptyRecoveredTranscript

    var errorDescription: String? {
        switch self {
        case .emptyRecoveredTranscript:
            "Fallback transcription produced no transcript."
        }
    }
}
