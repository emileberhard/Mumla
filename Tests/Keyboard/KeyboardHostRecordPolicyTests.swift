import Testing

@Suite("Keyboard host record policy")
struct KeyboardHostRecordPolicyTests {
    @Test func detectedHostReplacesTheCurrentRecord() {
        let current = KeyboardHostRecord(
            bundleIdentifier: "com.openai.chat",
            processIdentifier: 100
        )

        let updated = KeyboardHostRecordPolicy.updatedRecord(
            current: current,
            detectedBundleIdentifier: "com.anthropic.claude",
            processIdentifier: 200
        )

        #expect(updated == KeyboardHostRecord(
            bundleIdentifier: "com.anthropic.claude",
            processIdentifier: 200
        ))
    }

    @Test func failedDetectionPreservesTheHostForTheSameProcess() {
        let current = KeyboardHostRecord(
            bundleIdentifier: "com.openai.chat",
            processIdentifier: 100
        )

        let updated = KeyboardHostRecordPolicy.updatedRecord(
            current: current,
            detectedBundleIdentifier: nil,
            processIdentifier: 100
        )

        #expect(updated == current)
    }

    @Test func emptyDetectionPreservesTheHostForTheSameProcess() {
        let current = KeyboardHostRecord(
            bundleIdentifier: "com.openai.chat",
            processIdentifier: 100
        )

        let updated = KeyboardHostRecordPolicy.updatedRecord(
            current: current,
            detectedBundleIdentifier: "",
            processIdentifier: 100
        )

        #expect(updated == current)
    }

    @Test func failedDetectionClearsAHostFromAnotherProcess() {
        let current = KeyboardHostRecord(
            bundleIdentifier: "com.openai.chat",
            processIdentifier: 100
        )

        let updated = KeyboardHostRecordPolicy.updatedRecord(
            current: current,
            detectedBundleIdentifier: nil,
            processIdentifier: 200
        )

        #expect(updated == nil)
    }

    @Test func invalidProcessIdentifierNeverProducesARecord() {
        let updated = KeyboardHostRecordPolicy.updatedRecord(
            current: KeyboardHostRecord(
                bundleIdentifier: "com.openai.chat",
                processIdentifier: 100
            ),
            detectedBundleIdentifier: "com.anthropic.claude",
            processIdentifier: 0
        )

        #expect(updated == nil)
    }
}
