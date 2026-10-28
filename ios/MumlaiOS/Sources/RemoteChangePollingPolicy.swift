import SwiftUI

enum RemoteChangePollingPolicy {
    static func shouldPoll(in scenePhase: ScenePhase) -> Bool {
        scenePhase == .active
    }
}
