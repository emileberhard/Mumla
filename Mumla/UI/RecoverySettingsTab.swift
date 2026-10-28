import SwiftUI

struct RecoverySettingsTab: View {
    @Bindable var coordinator: FlowCoordinator

    var body: some View {
        VStack(alignment: .leading) {
            AudioArchiveView(dataStore: coordinator.dataStore) { id in
                coordinator.retryRecoverableTranscription(id: id)
            }
            if !coordinator.recoveryStatusMessage.isEmpty {
                Text(coordinator.recoveryStatusMessage)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding()
            }
        }
    }
}
