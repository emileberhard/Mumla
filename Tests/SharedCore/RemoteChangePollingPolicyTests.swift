import SwiftUI
import Testing

@Suite("Remote change polling policy")
struct RemoteChangePollingPolicyTests {
    @Test func pollsWhileTheSceneIsActive() {
        #expect(RemoteChangePollingPolicy.shouldPoll(in: .active))
    }

    @Test(arguments: [ScenePhase.inactive, .background])
    func stopsPollingWhileTheSceneIsNotActive(_ scenePhase: ScenePhase) {
        #expect(!RemoteChangePollingPolicy.shouldPoll(in: scenePhase))
    }
}
