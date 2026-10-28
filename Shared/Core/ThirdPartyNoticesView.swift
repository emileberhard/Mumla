import SwiftUI

struct ThirdPartyNoticesView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Third-party Notices")
        .task {
            do {
                text = try Self.load(bundle: .main)
            } catch {
                text = "The bundled third-party notices could not be loaded. Please reinstall Mumla."
            }
        }
    }

    private static func load(bundle: Bundle) throws -> String {
        guard let notices = bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let licenses = bundle.url(forResource: "LICENSES", withExtension: nil)
        else { throw CocoaError(.fileNoSuchFile) }
        let files = try FileManager.default.contentsOfDirectory(at: licenses, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let noticeText = try String(contentsOf: notices, encoding: .utf8)
        let licenseTexts = try files.map { url in
            "\n\n\(url.lastPathComponent)\n\n" + (try String(contentsOf: url, encoding: .utf8))
        }
        return noticeText + licenseTexts.joined()
    }
}
