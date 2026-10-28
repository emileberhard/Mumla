import CoreHaptics

/// Looping haptic texture played while dictation is actively recording:
/// a vintage handheld dictaphone with its cassette turning. Layers a soft
/// motor hum (two continuous events at different sharpness), a quasi-regular
/// tape-transport tick train with hand-authored jitter, a once-per-loop
/// flutter double-tick, and a slow "wow" intensity curve breathing the whole
/// mechanism. Design rationale lives in docs/haptics.md.
@MainActor
enum DictaphoneTexture {
    /// Single knob for overall subtlety; scales every authored intensity.
    static let intensityScale: Float = 0.7

    /// Reel speed: pure time-stretch applied by the player. 1.0 plays the
    /// authored 2.4 s loop (~7 ticks/s); lower stretches the whole mechanism
    /// without changing how each event feels.
    static let playbackRate: Float = 0.9

    private static let loopDuration: TimeInterval = 2.4

    /// (time, intensity, sharpness) per transient. The ~140 ms grid drifts
    /// by hand-authored jitter so the transport feels mechanical rather than
    /// metronomic; the 1.13/1.16 s pair is the flutter accent (the worn spot
    /// on the reel). The last tick sits one grid gap before the loop seam.
    private static let ticks: [(TimeInterval, Float, Float)] = [
        (0.07, 0.30, 0.35),
        (0.21, 0.24, 0.32),
        (0.36, 0.28, 0.38),
        (0.49, 0.22, 0.33),
        (0.65, 0.32, 0.36),
        (0.78, 0.24, 0.31),
        (0.93, 0.30, 0.37),
        (1.06, 0.22, 0.34),
        (1.13, 0.38, 0.28),
        (1.16, 0.30, 0.26),
        (1.22, 0.28, 0.35),
        (1.35, 0.25, 0.32),
        (1.50, 0.30, 0.36),
        (1.63, 0.23, 0.33),
        (1.79, 0.28, 0.38),
        (1.92, 0.24, 0.31),
        (2.07, 0.31, 0.35),
        (2.20, 0.23, 0.33),
        (2.33, 0.27, 0.36),
    ]

    static func pattern() throws -> CHHapticPattern {
        var events: [CHHapticEvent] = [
            hum(intensity: 0.20, sharpness: 0.10),
            hum(intensity: 0.12, sharpness: 0.38),
        ]
        events += ticks.map { time, intensity, sharpness in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * intensityScale),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: time
            )
        }

        // Wow: two shallow dips of unequal depth per loop. Endpoints stay at
        // 1.0 so the loop seam is smooth whether or not curve automation
        // re-triggers per loop iteration.
        let wow = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0.0, value: 1.0),
                .init(relativeTime: 0.35, value: 0.90),
                .init(relativeTime: 0.70, value: 1.0),
                .init(relativeTime: 1.20, value: 1.0),
                .init(relativeTime: 1.55, value: 0.85),
                .init(relativeTime: 1.90, value: 1.0),
                .init(relativeTime: loopDuration, value: 1.0),
            ],
            relativeTime: 0
        )

        return try CHHapticPattern(events: events, parameterCurves: [wow])
    }

    private static func hum(intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * intensityScale),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0,
            duration: loopDuration
        )
    }
}
