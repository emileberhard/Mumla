import Foundation
import Testing

@Suite("Host application return routes")
struct HostApplicationReturnRoutesTests {
    @Test func supportedHostsResolveToOrderedCustomSchemeURLs() {
        #expect(HostApplicationReturnRoutes.urls(for: "com.openai.chat") == [
            URL(string: "chatgpt://")!,
        ])
        #expect(HostApplicationReturnRoutes.urls(for: "com.google.gemini") == [
            URL(string: "gemini://")!,
            URL(string: "google-gemini://")!,
        ])
    }

    @Test func unknownHostHasNoReturnRoute() {
        #expect(HostApplicationReturnRoutes.urls(for: "com.example.unknown").isEmpty)
    }
}
