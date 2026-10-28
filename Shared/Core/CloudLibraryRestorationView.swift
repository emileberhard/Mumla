import SwiftUI

struct CloudLibraryRestorationView: View {
    let dataStore: MumlaDataStore
    @State private var showsCloudRestoreConfirmation = false
    @State private var expectedOwnerID: String?
    @State private var errorMessage: String?

    var body: some View {
        if dataStore.cloudDeletionNeedsDecision {
            VStack(alignment: .leading, spacing: 8) {
                Label("iCloud library deleted — sync paused", systemImage: "icloud.slash")
                Text("Your local copy is retained. Restoring uploads the retained library to iCloud again.").font(.caption)
                Button("Restore Retained Library") {
                    expectedOwnerID = dataStore.confirmedAccountID
                    showsCloudRestoreConfirmation = true
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .confirmationDialog("Restore this account's retained library to iCloud?", isPresented: $showsCloudRestoreConfirmation, titleVisibility: .visible) {
                Button("Restore Library") {
                    Task {
                        do {
                            guard let expectedOwnerID else { throw CancellationError() }
                            try await dataStore.restoreIntentionallyDeletedCloudLibrary(expectedOwnerID: expectedOwnerID); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
    }
}
