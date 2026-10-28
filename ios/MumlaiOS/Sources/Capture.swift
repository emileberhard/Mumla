#if MUMLA_SCREENSHOTS
import UIKit

enum Capture {
    static func onboarding() async {
        do {
            guard let directory = ProcessInfo.processInfo.environment["MUMLA_CAPTURE"].map({ URL(filePath: $0) }) else {
                throw CaptureError("MUMLA_CAPTURE names no output directory")
            }
            let png = try await snapshot(of: keyWindow())
            try png.write(to: directory.appending(path: "01.png"), options: .atomic)
            exit(0)
        } catch {
            print("capture failed: \(DiagnosticError(error).metadata)")
            exit(1)
        }
    }

    private static func keyWindow() async throws -> UIWindow {
        while true {
            let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            if let window = scene?.keyWindow {
                return window
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func snapshot(of window: UIWindow) async throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        while true {
            var complete = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if complete {
                guard let png = image.pngData() else { throw CaptureError("could not encode the screen as PNG") }
                return png
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

private struct CaptureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
