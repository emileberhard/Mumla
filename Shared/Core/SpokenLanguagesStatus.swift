import SwiftUI

struct SpokenLanguagesStatus: View {
    let owner: SpokenLanguagesOwner
    let library: UnifiedDictationLibrary

    var body: some View {
        switch owner {
        case .unavailable(.checking):
            LabeledContent("Loading your languages from iCloud") {
                ProgressView()
                    .controlSize(.small)
            }
        case .unavailable(.signedOut):
            Label("Sign in to iCloud to change your languages.", systemImage: "icloud.slash")
        case .unavailable(.noSharedProfile):
            Label("Set up your profile in Dictation Library to change your languages.", systemImage: "person.crop.circle.badge.plus")
        case .unavailable(.unreachable):
            retryRow("Can't reach iCloud to load your languages.", systemImage: "exclamationmark.icloud") {
                Task { await library.refresh() }
            }
            .disabled(library.isRefreshing)
        case .local, .profile:
            switch library.languagesSave {
            case .saving:
                LabeledContent("Saving") {
                    ProgressView()
                        .controlSize(.small)
                }
            case .failed:
                retryRow("Couldn't save your languages.", systemImage: "exclamationmark.triangle") {
                    library.retrySpokenLanguages()
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func retryRow(_ message: LocalizedStringKey, systemImage: String, retry: @escaping () -> Void) -> some View {
        HStack {
            Label(message, systemImage: systemImage)
                .foregroundStyle(.orange)
            Spacer()
            Button("Try Again", action: retry)
            .buttonStyle(.borderless)
        }
    }
}
