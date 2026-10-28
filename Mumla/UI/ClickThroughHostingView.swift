import Cocoa
import SwiftUI

/// NSHostingView subclass that accepts first mouse for non-activating panels
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}
