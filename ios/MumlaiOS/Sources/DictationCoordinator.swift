import AVFAudio
import CloudKit
import DictationLibrary
import Foundation
import Observation
import SpeechKit
import UIKit

enum SessionDuration: Int, CaseIterable, Sendable, Identifiable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600
    case never = 0

    var id: Self { self }

    var displayName: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .never: "Never"
        }
    }
}

/// Orchestrates dictation sessions, microphone capture, transcription, and the
/// App Group bridge to the keyboard extension. iOS counterpart of the macOS
/// app's FlowCoordinator.
@MainActor
@Observable
final class DictationCoordinator {
    private static let syncedPreferenceKeys = [SharedPreferenceKey.dictationLanguages]

    private let preferenceSync = CloudPreferenceStore()
    let access = MumlaAccess()
    var transcriber: AccessTranscriber { AccessTranscriber(access: access) }
    private let audioEngine = SessionAudioEngine()
    private let audioCommands: AsyncStream<AudioCommand>.Continuation
    private var audioCommandTask: Task<Void, Never>?
    private var hostSwitchbackTask: Task<Void, Never>?
#if MUMLA_SCREENSHOTS
    let dataStore = MumlaDataStore(cloudSyncEnabled: false)
#else
    let dataStore = MumlaDataStore(onPersistenceError: { error in
        CrashReporting.capture(
            message: "App data persistence failed",
            context: "persistence",
            error: error,
            metadata: [:]
        )
    })
#endif

    // MARK: - State

    private(set) var phase: DictationPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if phase == .recording {
                recordingStartDate = Date()
                scheduleRecordingStop()
            } else if oldValue == .recording {
                recordingStartDate = nil
            }
            publishState()
        }
    }

    /// When the current recording began; drives the elapsed timer shown in
    /// the dictation pill (in-app and, via the bridge, on the keyboard).
    private(set) var recordingStartDate: Date?

    private(set) var recordingLimit = TimeInterval(AccessGrant.progressiveAudioSeconds) {
        didSet {
            guard recordingLimit != oldValue else { return }
            scheduleRecordingStop()
            publishState()
        }
    }

    var recordingDeadline: Date? {
        recordingStartDate?.addingTimeInterval(recordingLimit)
    }

    private(set) var sessionActive = false {
        didSet {
            guard sessionActive != oldValue else { return }
            publishState()
        }
    }

    private(set) var sessionEndDate: Date?
    private(set) var lastErrorMessage = ""
    private(set) var transcript = ""
    private(set) var microphoneAuthorized = AVAudioApplication.shared.recordPermission == .granted
    private(set) var showSwipeBackHint = false
    private(set) var keyboardHasBeenActive = DictationBridge.keyboardHasBeenActive
    /// Settable: ContentView binds it to the history navigation push.
    var showTranscriptionHistory = false

    /// When false, the app root presents onboarding instead of the main view.
    var setupComplete: Bool {
        microphoneAuthorized && keyboardHasBeenActive
    }

    // MARK: - Settings

    /// Ordered ISO 639-1 codes; defaults to the system languages until the
    /// user edits the list in Settings.
    var dictationLanguages: [String] {
        didSet { preferenceSync.set(DictationLanguages.encode(dictationLanguages), forKey: SharedPreferenceKey.dictationLanguages) }
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

    func removeDictationLanguages(at offsets: IndexSet) {
        setSpokenLanguages(spokenLanguages.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element))
    }

    private func setSpokenLanguages(_ languages: [String]) {
        let edit: SpokenLanguagesEdit
        do {
            edit = try dataStore.library?.editSpokenLanguages(languages, iCloudSignedOut: access.state.isICloudSignedOut)
                ?? SpokenLanguagesOwner.local.edit(languages)
        } catch {
            CrashReporting.capture(message: "Spoken languages edit failed", context: "dictation_library", error: error)
            return
        }
        if case .local(let languages) = edit { dictationLanguages = languages }
    }

    var sessionDuration: SessionDuration {
        didSet {
            UserDefaults.standard.set(sessionDuration.rawValue, forKey: "sessionDuration")
            if sessionActive {
                scheduleSessionEnd()
            }
        }
    }

    var customVocabulary: [String] {
        dataStore.vocabularyTerms
    }

    func addVocabularyTerm(_ text: String) {
        dataStore.addVocabularyTerm(text)
    }

    func updateVocabularyTerm(_ entry: VocabularyEntry, to text: String) {
        dataStore.updateVocabularyTerm(entry, to: text)
    }

    func removeVocabularyTerms(at offsets: IndexSet, from entries: [VocabularyEntry]) {
        for offset in offsets where entries.indices.contains(offset) {
            dataStore.removeVocabularyTerm(entries[offset])
        }
    }

    // MARK: - Private

    private var bridgeObservers: [DarwinNotificationObserver] = []
    private var notificationObservers: [any NSObjectProtocol] = []
    private var heartbeatTask: Task<Void, Never>?
    private var sessionEndTask: Task<Void, Never>?
    private var levelPublishTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var keyboardInsertionReportTask: Task<Void, Never>?
    private var realtimeDictationController: RealtimeDictationController?
    private var realtimeCapture: (id: UUID, grant: Task<AccessGrant, any Error>)? {
        didSet { recordingStopTask?.cancel() }
    }
    private var recordingStopTask: Task<Void, Never>?
    private var accessPublishTask: Task<Void, Never>?
    private var routeValidation: ProbeSchedule?
    private var dictationStartedAt: Date?
    private var audioSessionInterrupted = false
    private var interruptionPause: ProbeSchedule?
    private var idleSessionRecovery: IdleSessionRecovery?
    private var interruptionBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(showSwipeBackHint: Bool = false) {
        let (audioCommandStream, audioCommands) = AsyncStream.makeStream(of: AudioCommand.self)
        self.audioCommands = audioCommands
        let defaults = UserDefaults.standard
        self.dictationLanguages = DictationLanguages.decode(preferenceSync.string(forKey: SharedPreferenceKey.dictationLanguages))
            ?? DictationLanguages.systemDefault()
        let savedDuration = defaults.object(forKey: "sessionDuration") as? Int
        self.sessionDuration = SessionDuration(rawValue: savedDuration ?? 0) ?? .fifteenMinutes
        self.showSwipeBackHint = showSwipeBackHint
        migrateLegacyVocabulary()
        KeychainStore.deleteRetiredAPIKeys()
        UIDevice.current.isBatteryMonitoringEnabled = true

        preferenceSync.observeRemoteChanges { [weak self] changedKeys in
            self?.syncFromCloud(changedKeys: changedKeys)
        }
        preferenceSync.pushCurrentValues(keys: Self.syncedPreferenceKeys)
        setupBridgeObservers()
        setupAudioSessionObservers()
        audioCommandTask = Task { [weak self] in
            for await command in audioCommandStream {
                await self?.perform(command)
            }
        }
        startHeartbeat()
        publishRecentTranscripts()
        publishState()
        accessPublishTask = Task { [weak self, access] in
            for await state in Observations({ access.state }) {
                self?.publishAccessState(state)
            }
        }
        CrashReporting.breadcrumb(
            "Dictation coordinator initialized",
            category: "diagnostics",
            metadata: diagnosticMetadata()
        )
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

    // MARK: - App lifecycle

    func applicationDidBecomeActive() {
        DictationBridge.setAppIsBackgrounded(false)
        microphoneAuthorized = AVAudioApplication.shared.recordPermission == .granted
        refreshKeyboardAccess()
        access.refreshInBackground()
        dataStore.fetchRemoteChanges()
        CrashReporting.breadcrumb(
            "Application became active",
            category: "lifecycle",
            metadata: diagnosticMetadata()
        )
        showPendingKeyboardLaunchIntent()
        if interruptionPause != nil {
            audioCommands.yield(.resumePausedDictation(trigger: "app_became_active"))
        }
        if IdleSessionPolicy.startsOnActivation(
            microphoneAuthorized: microphoneAuthorized,
            keyboardHasBeenActive: keyboardHasBeenActive,
            dictationAllowed: !access.state.blocksDictation,
            sessionActive: sessionActive
        ) {
            requestSessionStart()
        }
    }

    func refreshKeyboardAccess() {
        let lastActive = DictationBridge.keyboardLastActive
        if keyboardHasBeenActive != (lastActive != nil) {
            keyboardHasBeenActive = lastActive != nil
        }
    }

    func resetKeyboardAccessForOnboarding() {
        DictationBridge.sharedDefaults?.removeObject(forKey: DictationBridge.DefaultsKey.keyboardLastActiveTimestamp)
        refreshKeyboardAccess()
    }

    func applicationDidBecomeInactive() {
        CrashReporting.breadcrumb(
            "Application became inactive",
            category: "lifecycle",
            metadata: diagnosticMetadata()
        )
    }

    func applicationDidEnterBackground() {
        DictationBridge.setAppIsBackgrounded(true)
        CrashReporting.breadcrumb(
            "Application entered background",
            category: "lifecycle",
            metadata: diagnosticMetadata()
        )
        dismissSwipeBackHint()
    }

    func handle(url: URL) {
        if DictationBridge.isHistoryURL(url) {
            CrashReporting.breadcrumb(
                "Keyboard history URL handled",
                category: "lifecycle",
                metadata: diagnosticMetadata()
            )
            showTranscriptionHistory = true
            return
        }
        guard DictationBridge.isStartSessionURL(url) else { return }
        CrashReporting.breadcrumb(
            "Keyboard launch URL handled",
            category: "lifecycle",
            metadata: diagnosticMetadata(extra: ["url_path": url.path])
        )
        showSwipeBackHint = true
        requestSessionStart()
        scheduleKeyboardHostSwitchback()
    }

    func dismissSwipeBackHint() {
        showSwipeBackHint = false
    }

    private func scheduleKeyboardHostSwitchback() {
        hostSwitchbackTask?.cancel()
        guard let hostBundleIdentifier = DictationBridge.rememberedKeyboardHost else {
            CrashReporting.breadcrumb(
                "Keyboard host switchback skipped: host unidentified",
                category: "lifecycle",
                metadata: DictationBridge.keyboardHostDiagnostics()
            )
            return
        }

        hostSwitchbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(3)

            while !Task.isCancelled,
                  (!sessionActive || UIApplication.shared.applicationState != .active),
                  Date() < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  sessionActive,
                  UIApplication.shared.applicationState == .active
            else { return }

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  sessionActive,
                  UIApplication.shared.applicationState == .active
            else { return }

            CrashReporting.breadcrumb(
                "Keyboard host switchback attempting",
                category: "lifecycle",
                metadata: diagnosticMetadata(extra: [
                    "host_bundle_identifier": hostBundleIdentifier,
                ])
            )
            let opened = await HostApplicationSwitchback.open(
                bundleIdentifier: hostBundleIdentifier
            )
            CrashReporting.breadcrumb(
                opened ? "Keyboard host switchback opened" : "Keyboard host switchback failed",
                category: "lifecycle",
                metadata: diagnosticMetadata(extra: [
                    "host_bundle_identifier": hostBundleIdentifier,
                ])
            )
            if opened {
                dismissSwipeBackHint()
            }
        }
    }

    private func showPendingKeyboardLaunchIntent() {
        if DictationBridge.hasFreshKeyboardLaunchIntent() {
            showSwipeBackHint = true
        }
    }

    func requestMicrophonePermission() {
        CrashReporting.breadcrumb(
            "Microphone permission requested",
            category: "permission",
            metadata: diagnosticMetadata()
        )
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            microphoneAuthorized = granted
            CrashReporting.breadcrumb(
                "Microphone permission resolved",
                category: "permission",
                metadata: diagnosticMetadata(extra: ["granted": granted.description])
            )
            if granted {
                applicationDidBecomeActive()
            }
        }
    }

    // MARK: - Session

    func requestSessionStart() {
        audioCommands.yield(.startSession)
    }

    func requestSessionEnd() {
        audioCommands.yield(.endSession)
    }

    func requestDictationStart() {
        audioCommands.yield(.startDictation)
    }

    func requestDictationStop() {
        audioCommands.yield(.stopDictation)
    }

    func requestDictationCancel() {
        audioCommands.yield(.cancelDictation)
    }

    private func requestDictationStop(capture: UUID) {
        audioCommands.yield(.stopCapture(capture))
    }

    private func perform(_ command: AudioCommand) async {
        switch command {
        case .startSession:
            await startSession()
        case .endSession:
            await endSession()
        case .expireSession(let scheduledEnd):
            await expireSession(scheduledEnd: scheduledEnd)
        case .startDictation:
            await startDictation()
        case .stopDictation:
            await stopDictation()
        case .stopCapture(let id):
            guard realtimeCapture?.id == id else { return }
            await stopDictation()
        case .cancelDictation:
            await cancelDictation()
        case .interruption(let type, let reasonValue, let wasSuspended):
            await handleInterruption(type: type, reasonValue: reasonValue, wasSuspended: wasSuspended)
        case .mediaServicesReset:
            await handleMediaServicesReset()
        case .routeChanged(let routeMetadata):
            await handleAudioRouteChange(routeMetadata: routeMetadata)
        case .resumePausedDictation(let trigger):
            await attemptDictationResume(trigger: trigger)
        case .finalizePausedDictation(let pauseID, let reason):
            guard interruptionPause?.id == pauseID else { return }
            await finalizePausedDictation(reason: reason)
        case .retryIdleSessionRecovery(let recoveryID):
            await retryIdleSessionRecovery(recoveryID)
        case .abandonIdleSessionRecovery(let recoveryID):
            await abandonIdleSessionRecovery(recoveryID)
        case .validateDeferredRoute(let validationID, let attempt, let routeMetadata):
            await validateDeferredRoute(validationID, attempt: attempt, routeMetadata: routeMetadata)
        case .finishDeferredRouteValidation(let validationID, let routeMetadata):
            await finishDeferredRouteValidation(validationID, routeMetadata: routeMetadata)
        }
    }

    private func scheduleProbes(
        after delays: [Duration],
        attempt: @escaping @Sendable (UUID, Int) -> AudioCommand,
        exhausted: @escaping @Sendable (UUID) -> AudioCommand
    ) -> ProbeSchedule {
        let id = UUID()
        let task = Task { [audioCommands] in
            for (index, delay) in delays.enumerated() {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                audioCommands.yield(attempt(id, index + 1))
            }
            audioCommands.yield(exhausted(id))
        }
        return ProbeSchedule(id: id, task: task)
    }

    private func startSession() async {
        CrashReporting.breadcrumb(
            "Session start requested",
            category: "session",
            metadata: diagnosticMetadata()
        )
        guard !sessionActive else {
            CrashReporting.breadcrumb(
                "Session start ignored",
                category: "session",
                metadata: diagnosticMetadata(extra: ["reason": "already_active"])
            )
            return
        }
        guard microphoneAuthorized else {
            CrashReporting.breadcrumb(
                "Session start waiting for microphone permission",
                category: "session",
                metadata: diagnosticMetadata()
            )
            requestMicrophonePermission()
            return
        }
        lastErrorMessage = ""
        do {
            audioSessionInterrupted = false
            try await audioEngine.start()
        } catch {
            reportError(
                "Could not start the dictation session: \(error.localizedDescription)",
                error: error,
                metadata: ["operation": "audio_engine_start"]
            )
            return
        }
        sessionActive = true
        CrashReporting.breadcrumb(
            "Session started",
            category: "session",
            metadata: diagnosticMetadata()
        )
        scheduleSessionEnd()
    }

    private func endSession() async {
        CrashReporting.breadcrumb(
            "Session end requested",
            category: "session",
            metadata: diagnosticMetadata(extra: ["was_recording": (phase == .recording).description])
        )
        sessionEndTask?.cancel()
        sessionEndTask = nil
        cancelRouteValidation()
        stopIdleSessionRecovery()
        audioSessionInterrupted = false
        if phase == .recording || phase == .processing {
            await cancelDictation()
        }
        await audioEngine.stop()
        sessionActive = false
        sessionEndDate = nil
        phase = .idle
        publishState()
        CrashReporting.breadcrumb(
            "Session ended",
            category: "session",
            metadata: diagnosticMetadata()
        )
    }

    private func scheduleSessionEnd() {
        sessionEndTask?.cancel()
        sessionEndTask = nil
        guard sessionDuration != .never else {
            sessionEndDate = nil
            publishState()
            CrashReporting.breadcrumb(
                "Session auto-end disabled",
                category: "session",
                metadata: diagnosticMetadata()
            )
            return
        }
        let endDate = Date().addingTimeInterval(TimeInterval(sessionDuration.rawValue))
        sessionEndDate = endDate
        publishState()
        CrashReporting.breadcrumb(
            "Session auto-end scheduled",
            category: "session",
            metadata: diagnosticMetadata(extra: ["duration_seconds": String(sessionDuration.rawValue)])
        )
        scheduleSessionExpiry(for: endDate, after: .seconds(sessionDuration.rawValue))
    }

    private func scheduleSessionExpiry(for scheduledEnd: Date, after delay: Duration) {
        sessionEndTask = Task { [audioCommands] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            audioCommands.yield(.expireSession(scheduledEnd: scheduledEnd))
        }
    }

    private func expireSession(scheduledEnd: Date) async {
        guard sessionActive, sessionEndDate == scheduledEnd else { return }
        // Never cut an in-flight dictation; extend until it finishes.
        if phase == .recording || phase == .processing {
            scheduleSessionExpiry(for: scheduledEnd, after: .seconds(5))
            return
        }
        await endSession()
    }

    // MARK: - Dictation

    private func startDictation() async {
        CrashReporting.breadcrumb(
            "Dictation start requested",
            category: "dictation",
            metadata: diagnosticMetadata()
        )
        guard phase == .idle || phase == .error || phase == .success else {
            CrashReporting.breadcrumb(
                "Dictation start ignored",
                category: "dictation",
                metadata: diagnosticMetadata(extra: ["reason": "phase_not_ready"])
            )
            return
        }
        guard sessionActive else {
            reportError(
                "No active session. Open Mumla to start one.",
                metadata: ["reason": "no_active_audio_session"]
            )
            return
        }
        if let failure = access.state.blockingFailure {
            reportError(
                TranscriptionFailureMessage.text(for: failure, allowance: access.state),
                error: failure,
                metadata: ["reason": "access_blocked"]
            )
            return
        }
        let audioReadyForCapture = await audioEngine.isReadyForCapture
        if audioSessionInterrupted || !audioReadyForCapture {
            stopIdleSessionRecovery()
            do {
                try await restartAudioEngine(trigger: "dictation_start")
            } catch {
                await endSessionAfterFailedRestart(error)
                return
            }
        }
        lastErrorMessage = ""
        dictationStartedAt = Date()

        do {
            try await startRealtimeDictation()
        } catch {
            dictationStartedAt = nil
            await audioEngine.discardCapture()
            await restoreIdleAudioSessionAfterCapture(reason: "capture_start_failed")
            realtimeCapture?.grant.cancel()
            realtimeCapture = nil
            reportError(
                String(localized: "Couldn't start the microphone. Try again."),
                error: error,
                metadata: ["operation": "dictation_capture_start"]
            )
            return
        }

        phase = .recording
        CrashReporting.breadcrumb(
            "Dictation started",
            category: "dictation",
            metadata: diagnosticMetadata()
        )
        startPublishingAudioLevel()
    }

    private func stopDictation() async {
        guard phase == .recording else {
            CrashReporting.breadcrumb(
                "Dictation stop ignored",
                category: "dictation",
                metadata: diagnosticMetadata(extra: ["reason": "not_recording"])
            )
            return
        }
        clearInterruptionPauseState()
        let duration = dictationStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        CrashReporting.breadcrumb(
            "Dictation stop requested",
            category: "dictation",
            metadata: diagnosticMetadata(extra: ["recording_duration_ms": String(Int(duration * 1_000))])
        )
        stopPublishingAudioLevel()
        await stopRealtimeDictation()
    }

    private func cancelDictation() async {
        CrashReporting.breadcrumb(
            "Dictation cancel requested",
            category: "dictation",
            metadata: diagnosticMetadata()
        )
        clearInterruptionPauseState()
        stopPublishingAudioLevel()
        realtimeCapture?.grant.cancel()
        realtimeCapture = nil
        // A realtime stop may already be transcribing; cancel it so the
        // late transcript is not published after the user canceled.
        transcriptionTask?.cancel()
        transcriptionTask = nil
        let controller = realtimeDictationController
        realtimeDictationController = nil
        await archiveCanceledCapture()
        phase = .idle
        Task {
            await controller?.cancel()
        }
        await restoreIdleAudioSessionAfterCapture(reason: "dictation_canceled")
        CrashReporting.breadcrumb(
            "Realtime dictation canceled",
            category: "dictation",
            metadata: diagnosticMetadata()
        )
    }

    private func archiveCanceledCapture() async {
        let duration = dictationStartedAt.map { Date().timeIntervalSince($0) }
        dictationStartedAt = nil
        let audio = await audioEngine.endCapture()
        guard !audio.providerWAV.isEmpty else { return }
        Task {
            do {
                _ = try await dataStore.saveOriginalAudio(
                    await audio.original.value, source: "realtime",
                    durationMilliseconds: duration.map { Int($0 * 1_000) }
                )
            } catch {
                reportError("Canceled audio could not be archived: \(error.localizedDescription)", error: error)
            }
        }
    }

    // MARK: - Transcription

    private func transcribe(wavData: Data, recordingID: UUID) async throws -> String {
        let plan = dataStore.library?.plan(for: recordingID)
        if plan != nil { try await dataStore.library?.validateProviderCapture(recordingID) }
        let result = try await transcriber.transcribe(
            wav: wavData,
            languageHints: plan?.languages ?? dictationLanguages,
            customVocabulary: plan?.dictionary ?? customVocabulary
        )
        if let library = dataStore.library, plan != nil {
            try await library.recordProviderOutput(result.text, captureID: recordingID, model: TranscriptionProviderType.dictation.batchResultModelID)
        }

        var text = result.text
        if let lastChar = text.last, ".?!".contains(lastChar) {
            text.append(" ")
        }
        return text
    }

    // MARK: - Realtime Transcription

    private func scheduleRecordingStop() {
        recordingStopTask?.cancel()
        guard let capture = realtimeCapture?.id, let deadline = recordingDeadline else { return }
        recordingStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.requestDictationStop(capture: capture)
        }
    }

    private func startRealtimeDictation() async throws {
        let access = access
        let capture = UUID()
        let grant = Task { try await access.grant(maximumAudioSeconds: AccessGrant.progressiveAudioSeconds) }
        realtimeCapture = (capture, grant)
        recordingLimit = TimeInterval(AccessGrant.progressiveAudioSeconds)
        Task { [weak self] in
            switch await grant.result {
            case .success(let reserved) where self?.realtimeCapture?.id == capture:
                self?.recordingLimit = reserved.audioLimit
            case .failure(let error) where error is AccessFailure:
                self?.requestDictationStop(capture: capture)
            default:
                break
            }
        }
        let originalAudio = try await dataStore.makeOriginalAudioWriter(context: .prose)
        let plan = originalAudio.dictationPlan
        let providerConfiguration = RealtimeDictationProviderConfiguration(
            grant: grant,
            customVocabulary: plan?.dictionary ?? customVocabulary,
            languageHints: plan?.languages ?? dictationLanguages,
            onAudioLimitReached: { [weak self] in
                Task { @MainActor in self?.requestDictationStop(capture: capture) }
            }
        )

        let controller = RealtimeDictationController(
            providerConfiguration: providerConfiguration
        )
        try await audioEngine.beginCapture(
            onPCM16Data: controller.audioInput,
            sampleRate: controller.captureSampleRate,
            originalAudio: originalAudio
        )
        realtimeDictationController = controller
        CrashReporting.breadcrumb(
            "Realtime capture began",
            category: "audio_capture",
            metadata: diagnosticMetadata(
                extra: providerConfiguration.diagnosticsMetadata.merging(
                    ["diagnostics_session_id": controller.diagnosticsSessionID]
                ) { _, new in new }
            )
        )
    }

    private func stopRealtimeDictation() async {
        let duration = dictationStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        dictationStartedAt = nil

        let controller = realtimeDictationController
        realtimeCapture = nil
        let diagnosticsSessionID = controller?.diagnosticsSessionID ?? "missing"
        phase = .processing
        CrashReporting.breadcrumb(
            "Realtime capture tail started",
            category: "audio_capture",
            metadata: diagnosticMetadata(
                extra: [
                    "diagnostics_session_id": diagnosticsSessionID,
                    "recording_duration_ms": String(Int(duration * 1_000)),
                ]
            )
        )
        let captureTailStartedAt = Date()
        let audio = await audioEngine.endRealtimeCapture()
        let wavData = audio.providerWAV
        let captureDetails = [
            "capture_tail_ms": String(Int(Date().timeIntervalSince(captureTailStartedAt) * 1_000)),
            "diagnostics_session_id": diagnosticsSessionID,
            "recording_duration_ms": String(Int(duration * 1_000)),
            "wav_bytes": String(wavData.count),
        ]
        let captureMetadata = diagnosticMetadata(extra: captureDetails)
        transcriptionTask = Task(name: "iOSRealtimeStop") {
            guard !wavData.isEmpty else {
                await controller?.cancel()
                if !Task.isCancelled { phase = .idle }
                return
            }
            async let completion = duration >= 0.5 ? controller?.stop(recordingDurationMilliseconds: Int(duration * 1_000)) : nil
            let recordingID: UUID
            do {
                recordingID = try await dataStore.saveOriginalAudio(
                    await audio.original.value, source: "realtime",
                    durationMilliseconds: Int(duration * 1_000)
                )
            } catch {
                await controller?.cancel()
                guard !Task.isCancelled else { return }
                realtimeDictationController = nil
                reportError("Audio could not be archived: \(error.localizedDescription)", error: error)
                return
            }
            guard !Task.isCancelled else { return }
            guard duration >= 0.5, !wavData.isEmpty else {
                realtimeDictationController = nil
                CrashReporting.breadcrumb(
                    "Realtime capture discarded",
                    category: "audio_capture",
                    metadata: captureMetadata.merging(["reason": "too_short_or_empty"]) { _, new in new }
                )
                await controller?.cancel()
                phase = .idle
                return
            }

            CrashReporting.breadcrumb(
                "Realtime transcription stopping",
                category: "transcription",
                metadata: captureMetadata
            )
            realtimeDictationController = nil
            let result = await completion
            guard !Task.isCancelled else { return }
            CrashReporting.breadcrumb(
                "Realtime stop result received",
                category: "transcription",
                metadata: diagnosticMetadata(
                    extra: captureDetails.merging(
                        [
                            "fallback_reason": result?.fallbackReason ?? "none",
                            "realtime_character_count": String(result?.text?.count ?? 0),
                        ]
                    ) { _, new in new }
                )
            )

            do {
                let text: String
                if let realtimeText = result?.text, !realtimeText.isEmpty {
                    if let library = dataStore.library, library.plan(for: recordingID) != nil {
                        try await library.recordProviderOutput(realtimeText, captureID: recordingID, model: TranscriptionProviderType.dictation.libraryModelID)
                    }
                    text = realtimeText
                } else if let failure = result?.failure {
                    switch TranscriptionRecovery(after: failure) {
                    case .resendArchived:
                        CrashReporting.breadcrumb(
                            "Realtime falling back to batch transcription",
                            category: "transcription",
                            metadata: diagnosticMetadata(
                                extra: captureDetails.merging(
                                    ["fallback_reason": result?.fallbackReason ?? "missing_realtime_text"]
                                ) { _, new in new }
                            )
                        )
                        text = try await transcribe(wavData: wavData, recordingID: recordingID)
                    case .canceled:
                        phase = .idle
                        return
                    case .refused, .keepForRetry:
                        throw failure
                    }
                } else {
                    phase = .idle
                    return
                }
                guard !Task.isCancelled else { return }
                guard TranscriptSoundEvents.containsSpeech(text) else {
                    CrashReporting.breadcrumb(
                        "Transcript discarded as non-speech",
                        category: "transcription",
                        metadata: diagnosticMetadata(
                            extra: captureDetails.merging(
                                ["transcript_character_count": String(text.count)]
                            ) { _, new in new }
                        )
                    )
                    phase = .idle
                    return
                }
                dataStore.record(text: text, audioRecordingID: recordingID)
                publishTranscript(text)
                phase = .success
                CrashReporting.breadcrumb(
                    "Realtime transcription succeeded",
                    category: "transcription",
                    metadata: diagnosticMetadata(
                        extra: captureDetails.merging(
                            ["transcript_character_count": String(text.count)]
                        ) { _, new in new }
                    )
                )
                try? await Task.sleep(for: .seconds(1))
                if phase == .success {
                    phase = .idle
                }
            } catch {
                guard !Task.isCancelled else { return }
                reportError(
                    TranscriptionFailureMessage.text(for: error, allowance: access.state),
                    error: error,
                    metadata: captureDetails
                )
            }
        }
        await restoreIdleAudioSessionAfterCapture(reason: "dictation_stopped")
    }

    // MARK: - Keyboard bridge

    private func setupBridgeObservers() {
        bridgeObservers = [
            DarwinNotificationObserver(name: DictationBridge.Event.startRequested) { [weak self] in
                guard let self, let defaults = DictationBridge.sharedDefaults,
                      DictationBridge.consumeCommand(.start, defaults: defaults, now: Date()) else { return }
                self.requestDictationStart()
            },
            DarwinNotificationObserver(name: DictationBridge.Event.stopRequested) { [weak self] in
                guard let self, let defaults = DictationBridge.sharedDefaults,
                      DictationBridge.consumeCommand(.stop, defaults: defaults, now: Date()) else { return }
                self.requestDictationStop()
            },
            DarwinNotificationObserver(name: DictationBridge.Event.cancelRequested) { [weak self] in
                guard let self, let defaults = DictationBridge.sharedDefaults,
                      DictationBridge.consumeCommand(.cancel, defaults: defaults, now: Date()) else { return }
                self.requestDictationCancel()
            },
        ]
    }

    private func publishState() {
        guard let defaults = DictationBridge.sharedDefaults else { return }
        defaults.set(phase.rawValue, forKey: DictationBridge.DefaultsKey.phase)
        defaults.set(
            recordingStartDate?.timeIntervalSince1970 ?? 0,
            forKey: DictationBridge.DefaultsKey.recordingStartTimestamp
        )
        defaults.set(
            recordingDeadline?.timeIntervalSince1970 ?? 0,
            forKey: DictationBridge.DefaultsKey.recordingDeadlineTimestamp
        )
        defaults.set(sessionActive, forKey: DictationBridge.DefaultsKey.sessionActive)
        defaults.set(
            sessionEndDate?.timeIntervalSince1970 ?? 0,
            forKey: DictationBridge.DefaultsKey.sessionEndTimestamp
        )
        defaults.set(lastErrorMessage, forKey: DictationBridge.DefaultsKey.errorMessage)
        writeHeartbeat()
        DarwinNotifications.post(DictationBridge.Event.stateChanged)
    }

    private func publishAccessState(_ state: MumlaAccess.State) {
        guard let defaults = DictationBridge.sharedDefaults else { return }
        let keyboardState: KeyboardAccessState = switch state {
        case .checking: .checking
        case .available(let allowance) where allowance.isExhausted: .allowanceSpent(resetsAt: allowance.resetsAt)
        case .available: .available
        case .iCloudUnavailable(.noAccount): .iCloudSignedOut
        case .iCloudUnavailable: .iCloudUnavailable
        case .serviceUnavailable: .serviceUnavailable
        }
        keyboardState.write(to: defaults)
        DarwinNotifications.post(DictationBridge.Event.stateChanged)
    }

    private func publishTranscript(_ text: String) {
        transcript = text
        UIPasteboard.general.setObjects([text], localOnly: false, expirationDate: nil)

        guard let defaults = DictationBridge.sharedDefaults else { return }
        let transcriptID = UUID().uuidString
        defaults.set(transcriptID, forKey: DictationBridge.DefaultsKey.transcriptID)
        defaults.set(text, forKey: DictationBridge.DefaultsKey.transcriptText)
        defaults.set(Date().timeIntervalSince1970, forKey: DictationBridge.DefaultsKey.transcriptTimestamp)
        publishRecentTranscripts()
        if UIApplication.shared.applicationState != .active {
            scheduleKeyboardInsertionReport(for: transcriptID)
        }
    }

    private func scheduleKeyboardInsertionReport(for transcriptID: String) {
        keyboardInsertionReportTask?.cancel()
        keyboardInsertionReportTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(DictationBridge.keyboardInsertionReportDelay))
            } catch {
                return
            }
            guard let self else { return }
            let delivery = DictationBridge.keyboardTranscriptDiagnostics(transcriptID: transcriptID)
            let metadata = diagnosticMetadata(extra: delivery.merging(["transcript_id": transcriptID]) { _, new in new })
            if delivery["transcript_inserted"] == "true" {
                CrashReporting.breadcrumb("Keyboard inserted transcript", category: "keyboard_delivery", metadata: metadata)
            } else {
                CrashReporting.capture(
                    message: "Keyboard did not insert transcript",
                    context: "keyboard_delivery",
                    metadata: metadata
                )
            }
        }
    }

    private func publishRecentTranscripts() {
        DictationBridge.setRecentTranscripts(
            dataStore.recentHistoryTexts(limit: DictationBridge.recentTranscriptLimit)
        )
    }

    private func startPublishingAudioLevel() {
        levelPublishTask?.cancel()
        levelPublishTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                DictationBridge.sharedDefaults?.set(
                    self.audioEngine.currentLevel,
                    forKey: DictationBridge.DefaultsKey.audioLevel
                )
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopPublishingAudioLevel() {
        levelPublishTask?.cancel()
        levelPublishTask = nil
        DictationBridge.sharedDefaults?.set(0.0, forKey: DictationBridge.DefaultsKey.audioLevel)
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.writeHeartbeat()
                try? await Task.sleep(for: .seconds(DictationBridge.heartbeatInterval))
            }
        }
    }

    private func writeHeartbeat() {
        DictationBridge.sharedDefaults?.set(
            Date().timeIntervalSince1970,
            forKey: DictationBridge.DefaultsKey.heartbeat
        )
    }

    private func restoreIdleAudioSessionAfterCapture(reason: String) async {
        guard !audioSessionInterrupted else {
            CrashReporting.breadcrumb(
                "Idle audio session restore deferred",
                category: "audio_session",
                metadata: diagnosticMetadata(extra: ["reason": reason])
            )
            return
        }

        do {
            try await audioEngine.restoreIdleSessionAfterCapture()
            CrashReporting.breadcrumb(
                "Idle audio session restored",
                category: "audio_session",
                metadata: diagnosticMetadata(extra: ["reason": reason])
            )
        } catch {
            CrashReporting.breadcrumb(
                "Idle audio session restore failed",
                category: "audio_session",
                metadata: diagnosticMetadata(extra: ["reason": reason].merging(DiagnosticError(error).metadata) { _, safe in safe })
            )
            await recoverIdleAudioSession(trigger: "idle_restore_failed")
        }
    }

    // MARK: - Audio session notifications

    private func setupAudioSessionObservers() {
        let session = AVAudioSession.sharedInstance()
        let audioCommands = audioCommands
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            let reasonValue = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let wasSuspended = notification.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? Bool ?? false
            audioCommands.yield(.interruption(type, reasonValue: reasonValue, wasSuspended: wasSuspended))
        }

        let mediaReset = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { _ in
            audioCommands.yield(.mediaServicesReset)
        }

        let routeChange = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { notification in
            audioCommands.yield(.routeChanged(DictationCoordinator.audioRouteChangeMetadata(from: notification)))
        }

        // Force quit during an active session delivers willTerminate (the app
        // is running, not suspended). Publish the dead state synchronously —
        // a Task hop would not survive process exit — so the keyboard flips
        // instantly instead of waiting out the heartbeat stale window.
        let willTerminate = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            DictationCoordinator.publishAppTerminated()
        }

        let accountChanged = NotificationCenter.default.addObserver(forName: .mumlaAccountInvalidated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.transcriptionTask?.cancel()
                audioCommands.yield(.cancelDictation)
            }
        }
        notificationObservers = [interruption, mediaReset, routeChange, willTerminate, accountChanged]
    }

    private nonisolated static func publishAppTerminated() {
        guard let defaults = DictationBridge.sharedDefaults else { return }
        defaults.set(0.0, forKey: DictationBridge.DefaultsKey.heartbeat)
        defaults.set(false, forKey: DictationBridge.DefaultsKey.appIsBackgrounded)
        defaults.set(false, forKey: DictationBridge.DefaultsKey.sessionActive)
        defaults.set(DictationPhase.idle.rawValue, forKey: DictationBridge.DefaultsKey.phase)
        DarwinNotifications.post(DictationBridge.Event.stateChanged)
    }

    private func handleInterruption(
        type: AVAudioSession.InterruptionType,
        reasonValue: UInt?,
        wasSuspended: Bool
    ) async {
        CrashReporting.breadcrumb(
            "Audio session interruption",
            category: "audio_session",
            metadata: diagnosticMetadata(
                extra: [
                    "interruption_type": audioInterruptionDescription(type),
                    "interruption_reason_value": reasonValue.map(String.init) ?? "none",
                    "interruption_was_suspended": wasSuspended.description,
                ]
            )
        )
        switch type {
        case .began:
            audioSessionInterrupted = true
            cancelRouteValidation()
            stopIdleSessionRecovery()
            guard phase == .recording else { break }
            let action = DictationInterruptionPolicy.actionForInterruptionBegan(isStaleSuspensionNotice: wasSuspended)
            switch action {
            case .finalize:
                // Stale post-suspension notices finish with what was
                // captured so far.
                await stopDictation()
            case .pauseAndAutoResume:
                // A Siri-class announcement (Watch workout feedback, AirPods
                // readout) took the session. Park the capture and reclaim the
                // mic as soon as the system releases it — `.ended` is not
                // guaranteed and often omits `.shouldResume`, so probes drive
                // the resume rather than the notification.
                await pauseDictationForInterruption()
            }
        case .ended:
            audioSessionInterrupted = false
            if interruptionPause != nil {
                await attemptDictationResume(trigger: "interruption_ended")
            } else if sessionActive {
                await recoverIdleAudioSession(trigger: "interruption_ended")
            }
        @unknown default:
            break
        }
    }

    private func pauseDictationForInterruption() async {
        await audioEngine.suspendCaptureForInterruption()
        beginInterruptionBackgroundTask()
        interruptionPause = scheduleProbes(
            after: DictationInterruptionPolicy.resumeProbeDelays,
            attempt: { _, _ in .resumePausedDictation(trigger: "probe") },
            exhausted: { .finalizePausedDictation($0, reason: "resume_window_exhausted") }
        )
        CrashReporting.breadcrumb(
            "Dictation paused for interruption",
            category: "audio_session",
            metadata: diagnosticMetadata()
        )
    }

    /// Tries to reclaim the audio session and continue the paused capture.
    /// Fails harmlessly while the interrupting audio still holds the session.
    private func attemptDictationResume(trigger: String) async {
        guard interruptionPause != nil, phase == .recording else { return }
        do {
            try await audioEngine.resumeCaptureAfterInterruption()
        } catch {
            CrashReporting.breadcrumb(
                "Dictation resume attempt failed",
                category: "audio_session",
                metadata: diagnosticMetadata(extra: ["resume_trigger": trigger])
            )
            return
        }
        clearInterruptionPauseState()
        audioSessionInterrupted = false
        CrashReporting.breadcrumb(
            "Dictation resumed after interruption",
            category: "audio_session",
            metadata: diagnosticMetadata(extra: ["resume_trigger": trigger])
        )
    }

    private func finalizePausedDictation(reason: String) async {
        guard interruptionPause != nil else { return }
        CrashReporting.breadcrumb(
            "Paused dictation finalized",
            category: "audio_session",
            metadata: diagnosticMetadata(extra: ["reason": reason])
        )
        // stopDictation clears the pause state and transcribes the carried
        // capture; the engine does not need to be running for endCapture.
        await stopDictation()
        endInterruptionBackgroundTask()
    }

    private func clearInterruptionPauseState() {
        guard let interruptionPause else { return }
        interruptionPause.task.cancel()
        self.interruptionPause = nil
        endInterruptionBackgroundTask()
    }

    /// Keeps the app running while a background dictation waits out an
    /// interruption; without this iOS may suspend the process (its audio
    /// session is inactive) before any resume probe can fire.
    private func beginInterruptionBackgroundTask() {
        guard interruptionBackgroundTask == .invalid else { return }
        interruptionBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "DictationInterruptionRecovery"
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let interruptionPause = self.interruptionPause {
                    self.audioCommands.yield(
                        .finalizePausedDictation(interruptionPause.id, reason: "background_task_expired")
                    )
                }
                self.endInterruptionBackgroundTask()
            }
        }
    }

    private func endInterruptionBackgroundTask() {
        guard interruptionBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(interruptionBackgroundTask)
        interruptionBackgroundTask = .invalid
    }

    private func handleMediaServicesReset() async {
        await audioEngine.discardEngineAfterMediaServicesReset()
        CrashReporting.breadcrumb(
            "Audio media services reset",
            category: "audio_session",
            metadata: diagnosticMetadata()
        )
        audioSessionInterrupted = false
        cancelRouteValidation()
        if phase == .recording {
            await stopDictation()
        } else if sessionActive {
            await recoverIdleAudioSession(trigger: "media_services_reset")
        }
    }

    private func handleAudioRouteChange(routeMetadata: [String: String]) async {
        // Announcements often release the session with a route change rather
        // than a timely `.ended`; a resume attempt here is a cheap no-op if
        // the system still holds the session.
        if interruptionPause != nil {
            await attemptDictationResume(trigger: "route_change")
        }
        let inputRoute = await audioEngine.handleRouteChange()
        CrashReporting.breadcrumb(
            "Audio route changed",
            category: "audio_route",
            metadata: diagnosticMetadata(extra: routeMetadata)
        )
        guard sessionActive, phase == .recording else { return }
        if AudioRouteValidationPolicy.shouldDeferBuiltInMicrophoneValidation(
            route: inputRoute,
            interruptionActive: audioSessionInterrupted
        ) {
            scheduleBuiltInMicrophoneRouteValidation(routeMetadata: routeMetadata)
            return
        }

        await validateBuiltInMicrophoneRoute(routeMetadata: routeMetadata, deferred: false, attempt: nil)
    }

    private func scheduleBuiltInMicrophoneRouteValidation(routeMetadata: [String: String]) {
        cancelRouteValidation()
        CrashReporting.breadcrumb(
            "Audio route validation deferred",
            category: "audio_route",
            metadata: diagnosticMetadata(extra: routeMetadata)
        )
        routeValidation = scheduleProbes(
            after: AudioRouteValidationPolicy.retryDelays,
            attempt: { .validateDeferredRoute($0, attempt: $1, routeMetadata: routeMetadata) },
            exhausted: { .finishDeferredRouteValidation($0, routeMetadata: routeMetadata) }
        )
    }

    private func validateDeferredRoute(_ validationID: UUID, attempt: Int, routeMetadata: [String: String]) async {
        guard routeValidation?.id == validationID else { return }
        guard sessionActive else {
            cancelRouteValidation()
            return
        }
        if AudioRouteValidationPolicy.shouldDeferBuiltInMicrophoneValidation(
            route: await audioEngine.inputRouteState(),
            interruptionActive: audioSessionInterrupted
        ) {
            return
        }
        cancelRouteValidation()
        await validateBuiltInMicrophoneRoute(routeMetadata: routeMetadata, deferred: true, attempt: attempt)
    }

    private func finishDeferredRouteValidation(_ validationID: UUID, routeMetadata: [String: String]) async {
        guard routeValidation?.id == validationID else { return }
        cancelRouteValidation()
        guard sessionActive, !audioSessionInterrupted else { return }
        await validateBuiltInMicrophoneRoute(
            routeMetadata: routeMetadata,
            deferred: true,
            attempt: AudioRouteValidationPolicy.retryDelays.count + 1
        )
    }

    private func cancelRouteValidation() {
        routeValidation?.task.cancel()
        routeValidation = nil
    }

    private func validateBuiltInMicrophoneRoute(
        routeMetadata: [String: String],
        deferred: Bool,
        attempt: Int?
    ) async {
        var metadata = routeMetadata
        metadata["route_validation_deferred"] = deferred.description
        if let attempt {
            metadata["route_validation_attempt"] = String(attempt)
        }

        do {
            try await audioEngine.enforcePreferredAudioRoute()
            CrashReporting.breadcrumb(
                "Audio route validated",
                category: "audio_route",
                metadata: diagnosticMetadata(extra: metadata)
            )
        } catch {
            reportError(
                "Built-in microphone is unavailable; Mumla will not use another microphone.",
                error: error,
                metadata: metadata
            )
            await endSession()
        }
    }

    private func recoverIdleAudioSession(trigger: String) async {
        stopIdleSessionRecovery()
        do {
            try await restartAudioEngine(trigger: trigger)
        } catch {
            beginInterruptionBackgroundTask()
            idleSessionRecovery = IdleSessionRecovery(
                probes: scheduleProbes(
                    after: DictationInterruptionPolicy.resumeProbeDelays,
                    attempt: { recoveryID, _ in .retryIdleSessionRecovery(recoveryID) },
                    exhausted: { .abandonIdleSessionRecovery($0) }
                ),
                lastFailure: error
            )
        }
    }

    private func retryIdleSessionRecovery(_ recoveryID: UUID) async {
        guard idleSessionRecovery?.probes.id == recoveryID else { return }
        do {
            try await restartAudioEngine(trigger: "probe")
            stopIdleSessionRecovery()
        } catch {
            idleSessionRecovery?.lastFailure = error
        }
    }

    private func abandonIdleSessionRecovery(_ recoveryID: UUID) async {
        guard let idleSessionRecovery, idleSessionRecovery.probes.id == recoveryID else { return }
        stopIdleSessionRecovery()
        await endSessionAfterFailedRestart(idleSessionRecovery.lastFailure)
    }

    private func stopIdleSessionRecovery() {
        guard let idleSessionRecovery else { return }
        idleSessionRecovery.probes.task.cancel()
        self.idleSessionRecovery = nil
        endInterruptionBackgroundTask()
    }

    private func restartAudioEngine(trigger: String) async throws {
        cancelRouteValidation()
        CrashReporting.breadcrumb(
            "Audio engine restart requested",
            category: "audio_session",
            metadata: diagnosticMetadata(extra: ["restart_trigger": trigger])
        )
        do {
            try await audioEngine.restart()
        } catch {
            CrashReporting.breadcrumb(
                "Audio engine restart attempt failed",
                category: "audio_session",
                metadata: diagnosticMetadata(extra: ["restart_trigger": trigger].merging(DiagnosticError(error).metadata) { _, safe in safe })
            )
            throw error
        }
        audioSessionInterrupted = false
        CrashReporting.breadcrumb(
            "Audio engine restarted",
            category: "audio_session",
            metadata: diagnosticMetadata(extra: ["restart_trigger": trigger])
        )
    }

    private func endSessionAfterFailedRestart(_ error: any Error) async {
        reportError(
            "Microphone session was interrupted and could not be restored.",
            error: error,
            metadata: ["operation": "audio_engine_restart"]
        )
        await endSession()
    }

    // MARK: - Diagnostics

    private func diagnosticMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata: [String: String] = [
            "application_state": applicationStateDescription(UIApplication.shared.applicationState),
            "background_time_remaining": backgroundTimeRemainingDescription(UIApplication.shared.backgroundTimeRemaining),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled.description,
            "microphone_authorized": microphoneAuthorized.description,
            "phase": phase.rawValue,
            "session_active": sessionActive.description,
            "thermal_state": thermalStateDescription(ProcessInfo.processInfo.thermalState),
        ]
        metadata.merge(devicePowerMetadata()) { _, new in new }
        metadata.merge(audioEngine.diagnostics) { _, new in new }
        metadata.merge(extra) { _, new in new }
        return metadata
    }

    private func devicePowerMetadata() -> [String: String] {
        let device = UIDevice.current
        let batteryLevel = device.batteryLevel
        return [
            "battery_level_percent": batteryLevel >= 0 ? String(Int((batteryLevel * 100).rounded())) : "unknown",
            "battery_monitoring_enabled": device.isBatteryMonitoringEnabled.description,
            "battery_state": batteryStateDescription(device.batteryState),
        ]
    }

    private nonisolated static func audioRouteChangeMetadata(from notification: Notification) -> [String: String] {
        var metadata: [String: String] = [:]
        if let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) {
            metadata["route_change_reason"] = routeChangeReasonDescription(reason)
            metadata["route_change_reason_value"] = String(reasonValue)
        } else {
            metadata["route_change_reason"] = "unknown"
        }

        if let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            metadata["previous_route_inputs"] = AudioPortDiagnostics.describe(previousRoute.inputs)
            metadata["previous_route_outputs"] = AudioPortDiagnostics.describe(previousRoute.outputs)
        }
        return metadata
    }

    private nonisolated static func routeChangeReasonDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown:
            "unknown"
        case .newDeviceAvailable:
            "new_device_available"
        case .oldDeviceUnavailable:
            "old_device_unavailable"
        case .categoryChange:
            "category_change"
        case .override:
            "override"
        case .wakeFromSleep:
            "wake_from_sleep"
        case .noSuitableRouteForCategory:
            "no_suitable_route_for_category"
        case .routeConfigurationChange:
            "route_configuration_change"
        @unknown default:
            "unknown_future_reason"
        }
    }

    private func audioInterruptionDescription(_ type: AVAudioSession.InterruptionType) -> String {
        switch type {
        case .began:
            "began"
        case .ended:
            "ended"
        @unknown default:
            "unknown_future_interruption"
        }
    }

    private func batteryStateDescription(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:
            "unknown"
        case .unplugged:
            "unplugged"
        case .charging:
            "charging"
        case .full:
            "full"
        @unknown default:
            "unknown_future_battery_state"
        }
    }

    private func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown_future_thermal_state"
        }
    }

    private func applicationStateDescription(_ state: UIApplication.State) -> String {
        switch state {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown_future_application_state"
        }
    }

    private func backgroundTimeRemainingDescription(_ timeRemaining: TimeInterval) -> String {
        if timeRemaining == .greatestFiniteMagnitude {
            return "unlimited"
        }
        guard timeRemaining.isFinite, timeRemaining >= 0 else {
            return "unknown"
        }
        return String(Int(timeRemaining.rounded()))
    }

    // MARK: - Errors

    private func reportError(_ message: String, error: Error? = nil, metadata: [String: String] = [:]) {
        lastErrorMessage = message
        phase = .error
        publishState()
        CrashReporting.capture(
            message: "Dictation operation failed",
            context: "dictation",
            error: error,
            metadata: diagnosticMetadata(extra: metadata)
        )
        Task {
            try? await Task.sleep(for: .seconds(2))
            if phase == .error {
                phase = .idle
            }
        }
    }
}

private nonisolated enum AudioCommand: Sendable {
    case startSession
    case endSession
    case expireSession(scheduledEnd: Date)
    case startDictation
    case stopDictation
    case stopCapture(UUID)
    case cancelDictation
    case interruption(AVAudioSession.InterruptionType, reasonValue: UInt?, wasSuspended: Bool)
    case mediaServicesReset
    case routeChanged([String: String])
    case resumePausedDictation(trigger: String)
    case finalizePausedDictation(UUID, reason: String)
    case retryIdleSessionRecovery(UUID)
    case abandonIdleSessionRecovery(UUID)
    case validateDeferredRoute(UUID, attempt: Int, routeMetadata: [String: String])
    case finishDeferredRouteValidation(UUID, routeMetadata: [String: String])
}

private struct ProbeSchedule {
    let id: UUID
    let task: Task<Void, Never>
}

private struct IdleSessionRecovery {
    let probes: ProbeSchedule
    var lastFailure: any Error
}
