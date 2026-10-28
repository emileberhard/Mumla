import CoreHaptics

/// One-shot accents bracketing the dictaphone texture: the cassette popping
/// in and out of a vintage handheld recorder. Pure transients at full
/// intensity, spaced ~90 ms so the rhythm is unhurried but still tight; no
/// continuous bodies anywhere — sustained material smears the mechanism,
/// and the motor is the texture loop's job. Every hit is a 13 ms transient
/// pair, which merges into one thick, rigid snap: the lead transient's
/// sharpness sets the click's edge, the companion's weight sets its mass.
/// Start climbs into its heaviest hit (cassette seating), stop leads with
/// it (eject latch letting go), so the two read unambiguously without
/// looking. Design rationale lives in docs/haptics.md.
@MainActor
enum DictaphoneAccents {
    /// Cassette in: click-click-CLACK, climbing — each hit rounder and
    /// heavier than the last.
    static func startPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            transient(time: 0, intensity: 1.0, sharpness: 0.75), // latch contact
            transient(time: 0.013, intensity: 0.6, sharpness: 0.4),
            transient(time: 0.09, intensity: 1.0, sharpness: 0.65), // mechanism seats
            transient(time: 0.103, intensity: 0.65, sharpness: 0.35),
            transient(time: 0.185, intensity: 1.0, sharpness: 0.45), // locks in
            transient(time: 0.198, intensity: 0.9, sharpness: 0.25),
        ], parameters: [])
    }

    /// Cassette out: snick-CLACK-click, falling away.
    static func stopPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            transient(time: 0, intensity: 1.0, sharpness: 0.8), // stop-key snick
            transient(time: 0.013, intensity: 0.55, sharpness: 0.5),
            transient(time: 0.09, intensity: 1.0, sharpness: 0.4), // eject pop
            transient(time: 0.103, intensity: 0.9, sharpness: 0.25),
            transient(time: 0.18, intensity: 0.95, sharpness: 0.6), // shell pops up
            transient(time: 0.193, intensity: 0.6, sharpness: 0.35),
        ], parameters: [])
    }

    private static func transient(
        time: TimeInterval,
        intensity: Float,
        sharpness: Float
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }
}
