enum IdleSessionPolicy {
    static func startsOnActivation(
        microphoneAuthorized: Bool,
        keyboardHasBeenActive: Bool,
        dictationAllowed: Bool,
        sessionActive: Bool
    ) -> Bool {
        microphoneAuthorized && keyboardHasBeenActive && dictationAllowed && !sessionActive
    }
}
