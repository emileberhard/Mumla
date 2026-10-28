import Foundation

struct AudioInputRouteState: Equatable, Sendable {
    let builtInMicrophoneAvailable: Bool
    let routeHasInputs: Bool
    let routesBuiltInMicrophone: Bool
}

enum AudioRouteValidationPolicy {
    static let retryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(750),
        .seconds(1),
        .seconds(2),
    ]

    static func shouldDeferBuiltInMicrophoneValidation(
        route: AudioInputRouteState,
        interruptionActive: Bool
    ) -> Bool {
        if interruptionActive {
            return true
        }

        return route.builtInMicrophoneAvailable && !route.routeHasInputs
    }
}
