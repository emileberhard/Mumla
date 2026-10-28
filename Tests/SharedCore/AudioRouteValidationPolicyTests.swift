import Testing

@Suite("Audio route validation policy")
struct AudioRouteValidationPolicyTests {
    @Test func defersWhileTheBuiltInMicrophoneRouteIsStillBeingApplied() {
        let route = AudioInputRouteState(
            builtInMicrophoneAvailable: true,
            routeHasInputs: false,
            routesBuiltInMicrophone: false
        )

        #expect(AudioRouteValidationPolicy.shouldDeferBuiltInMicrophoneValidation(route: route, interruptionActive: false))
    }

    @Test func validatesImmediatelyWhenTheBuiltInMicrophoneIsUnavailable() {
        let route = AudioInputRouteState(
            builtInMicrophoneAvailable: false,
            routeHasInputs: false,
            routesBuiltInMicrophone: false
        )

        #expect(!AudioRouteValidationPolicy.shouldDeferBuiltInMicrophoneValidation(route: route, interruptionActive: false))
    }

    @Test func validatesImmediatelyWhenAnotherInputIsRouted() {
        let route = AudioInputRouteState(
            builtInMicrophoneAvailable: true,
            routeHasInputs: true,
            routesBuiltInMicrophone: false
        )

        #expect(!AudioRouteValidationPolicy.shouldDeferBuiltInMicrophoneValidation(route: route, interruptionActive: false))
    }

    @Test func defersDuringAnInterruption() {
        let route = AudioInputRouteState(
            builtInMicrophoneAvailable: false,
            routeHasInputs: false,
            routesBuiltInMicrophone: false
        )

        #expect(AudioRouteValidationPolicy.shouldDeferBuiltInMicrophoneValidation(route: route, interruptionActive: true))
    }
}
