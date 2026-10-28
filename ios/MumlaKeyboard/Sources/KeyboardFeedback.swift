import CoreHaptics
import UIKit

final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        allowsSelfSizing = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowsSelfSizing = true
    }
}

@MainActor
final class KeyboardFeedback {
    private static let keyImpactIntensity: CGFloat = 1.0
    private static let controlImpactIntensity: CGFloat = 0.75

    /// A flip to `.recording` older than this is the keyboard re-observing
    /// an already-running mechanism, not an engage — no accent.
    private static let startAccentFreshness: TimeInterval = 2
    /// The automatic-start handoff and the phase-driven path both deliver
    /// the start accent; whichever runs first wins within this window.
    private static let startAccentDebounce: Duration = .seconds(1.5)

    private weak var inputView: UIView?
    private var keyImpact: UIImpactFeedbackGenerator?
    private var hapticEngine: CHHapticEngine?
    private var startAccentPlayer: (any CHHapticPatternPlayer)?
    private var stopAccentPlayer: (any CHHapticPatternPlayer)?
    private var lastStartAccent: ContinuousClock.Instant?
    private var texturePlayer: (any CHHapticAdvancedPatternPlayer)?
    private var textureShouldBePlaying = false
    private var textureRestoreTask: Task<Void, Never>?
    private var isActive = false

    init(inputView: UIView) {
        self.inputView = inputView
        activate()
    }

    func activate() {
        isActive = true
        if keyImpact == nil, let inputView {
            keyImpact = UIImpactFeedbackGenerator(style: .light, view: inputView)
        }
        keyImpact?.prepare()
    }

    func deactivate() {
        isActive = false
        keyImpact = nil
        textureShouldBePlaying = false
        stopTexture()
        discardHapticEngine()
        stopAccentPlayer = nil
    }

    func keyPressed(at location: CGPoint) {
        UIDevice.current.playInputClick()
        playImpact(intensity: Self.keyImpactIntensity, at: location)
    }

    func controlPressed(at location: CGPoint) {
        playImpact(intensity: Self.controlImpactIntensity, at: location)
    }

    func automaticDictationStarted() async throws -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }

        let previousStartAccent = lastStartAccent
        let startAccent = ContinuousClock.now
        lastStartAccent = startAccent
        do {
            let engine = try await startedHapticEngine()
            let player = try engine.makePlayer(with: DictaphoneAccents.startPattern())
            startAccentPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            if lastStartAccent == startAccent {
                lastStartAccent = previousStartAccent
            }
            discardHapticEngine()
            throw error
        }
    }

    /// Plays the record-engage accent when observed dictation flips to
    /// recording. Skips stale flips (reopening the keyboard mid-recording
    /// engages nothing mechanically) and debounces against the
    /// automatic-start handoff, which delivers the same accent through its
    /// own durable path.
    func dictationStarted(recordingStart: Date?) {
        if let recordingStart,
           Date().timeIntervalSince(recordingStart) > Self.startAccentFreshness {
            return
        }
        if let lastStartAccent, lastStartAccent.duration(to: .now) < Self.startAccentDebounce {
            return
        }
        let previousStartAccent = lastStartAccent
        let startAccent = ContinuousClock.now
        lastStartAccent = startAccent
        Task {
            guard let player = await playAccent(try? DictaphoneAccents.startPattern()) else {
                if lastStartAccent == startAccent {
                    lastStartAccent = previousStartAccent
                }
                return
            }
            startAccentPlayer = player
        }
    }

    /// Plays the stop-key release and motor spin-down when recording ends;
    /// the texture has just been cut, so this is the mechanism's falling
    /// tail.
    func dictationStopped() {
        Task {
            stopAccentPlayer = await playAccent(try? DictaphoneAccents.stopPattern())
        }
    }

    /// Starts or stops the looping dictaphone texture. Bound to observed
    /// dictation state, never to the event that started dictation, so it
    /// survives engine resets and keyboard controller replacement.
    func setDictationTextureActive(_ active: Bool) {
        guard active != textureShouldBePlaying else { return }
        textureShouldBePlaying = active
        if active {
            scheduleTextureRestore()
        } else {
            stopTexture()
        }
    }

    private func makeHapticEngine() throws -> CHHapticEngine {
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        // Core Haptics invokes both handlers on its own internal queue
        // (stops include auto-shutdown and audio interruptions). @Sendable
        // keeps the closures nonisolated instead of silently inheriting
        // MainActor; all main-actor work happens after an explicit hop.
        engine.stoppedHandler = { @Sendable [weak self] reason in
            NSLog("Keyboard haptic engine stopped: %ld", reason.rawValue)
            Task { @MainActor in
                self?.scheduleTextureRestore()
            }
        }
        engine.resetHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let engine = self.hapticEngine {
                    try? await engine.start()
                }
                self.scheduleTextureRestore()
            }
        }
        return engine
    }

    private func discardHapticEngine() {
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
        startAccentPlayer = nil
    }

    private func startedHapticEngine() async throws -> CHHapticEngine {
        guard isActive else { throw CancellationError() }
        let engine = try hapticEngine ?? makeHapticEngine()
        hapticEngine = engine
        try await engine.start()
        guard isActive, hapticEngine === engine else { throw CancellationError() }
        return engine
    }

    /// Engine stops and server resets kill every player. Rebuild the texture
    /// loop while it should still be playing; audio-session interruptions can
    /// hold the haptic server for a few seconds, hence the retries.
    private func scheduleTextureRestore() {
        guard textureShouldBePlaying else { return }
        textureRestoreTask?.cancel()
        textureRestoreTask = Task { @MainActor [weak self] in
            for _ in 0..<5 {
                guard let self, self.textureShouldBePlaying, !Task.isCancelled else { return }
                if await self.startTexture() { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startTexture() async -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return true }
        do {
            texturePlayer?.loopEnabled = false
            try? texturePlayer?.stop(atTime: CHHapticTimeImmediate)
            let engine = try await startedHapticEngine()
            guard textureShouldBePlaying else { return true }

            let player = try engine.makeAdvancedPlayer(with: DictaphoneTexture.pattern())
            player.loopEnabled = true
            player.playbackRate = DictaphoneTexture.playbackRate
            try player.start(atTime: CHHapticTimeImmediate)
            texturePlayer = player
            return true
        } catch {
            texturePlayer = nil
            NSLog("Dictation texture start failed: %@", DiagnosticError(error).metadata.description)
            return false
        }
    }

    /// Fires a one-shot accent and returns its player, which the caller must
    /// retain until playback finishes. Accents are best-effort: on failure
    /// the state-driven texture still tells the story.
    private func playAccent(_ pattern: CHHapticPattern?) async -> (any CHHapticPatternPlayer)? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let pattern else {
            return nil
        }
        do {
            let engine = try await startedHapticEngine()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return player
        } catch {
            NSLog("Dictation accent failed: %@", DiagnosticError(error).metadata.description)
            return nil
        }
    }

    private func stopTexture() {
        textureRestoreTask?.cancel()
        textureRestoreTask = nil
        // Clear the loop before stopping so the sequence can't be released
        // while Core Haptics still considers it looping.
        texturePlayer?.loopEnabled = false
        try? texturePlayer?.stop(atTime: CHHapticTimeImmediate)
        texturePlayer = nil
    }

    private func playImpact(intensity: CGFloat, at location: CGPoint) {
        activate()
        keyImpact?.impactOccurred(intensity: intensity, at: location)
        keyImpact?.prepare()
    }
}
