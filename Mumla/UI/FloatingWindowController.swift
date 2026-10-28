import Cocoa
import SwiftUI

@MainActor
final class FloatingWindowController {
    static let shared = FloatingWindowController()

    private var window: NSPanel!
    private var hostingView: ClickThroughHostingView<FloatingIndicatorView>?
    private var currentScreen: NSScreen?

    private init() {
        setupWindow()
    }

    private func setupWindow() {
        let rootView = FloatingIndicatorView()
        let hostingView = ClickThroughHostingView(rootView: rootView)
        hostingView.sizingOptions = [.preferredContentSize]
        self.hostingView = hostingView

        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: FloatingIndicatorView.windowSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = false
        // Start with click-through enabled - we toggle dynamically based on mouse position
        window.ignoresMouseEvents = true

        window.contentView = hostingView

        Task { [weak self] in
            guard let self, let hostingView = self.hostingView else { return }
            for await _ in NotificationCenter.default.notifications(named: NSView.frameDidChangeNotification, object: hostingView) {
                self.centerOnActiveScreen()
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.activeSpaceDidChangeNotification) {
                self.centerOnActiveScreen()
            }
        }

        // Global monitor for mouse movement - handles click-through toggling and screen tracking
        // Use assumeIsolated for synchronous updates (we're on main thread)
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.updateMouseEventHandling()
                let newScreen = self.screenWithMouse()
                if newScreen != self.currentScreen {
                    self.centerOnActiveScreen()
                }
            }
        }

        // Local monitor for when window is receiving events (mouse over pill)
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.updateMouseEventHandling()
            }
            return event
        }

        centerOnActiveScreen()
    }

    func refreshMouseEventHandling() {
        updateMouseEventHandling()
    }

    private func updateMouseEventHandling() {
        let mouseLocation = NSEvent.mouseLocation
        let windowFrame = window.frame

        // If mouse is outside window bounds, enable click-through
        guard windowFrame.contains(mouseLocation) else {
            if !window.ignoresMouseEvents {
                window.ignoresMouseEvents = true
            }
            return
        }

        let localPoint = NSPoint(
            x: mouseLocation.x - windowFrame.origin.x,
            y: mouseLocation.y - windowFrame.origin.y
        )
        let windowBounds = CGRect(origin: .zero, size: windowFrame.size)
        let isIdle = FlowCoordinator.shared.state == .idle
        let isHovering = isIdle && !window.ignoresMouseEvents
        let shouldAcceptEvents = FloatingIndicatorView.containsPointInVisibleCapsule(
            localPoint,
            bounds: windowBounds,
            isIdle: isIdle,
            isHovering: isHovering
        )
        let shouldIgnoreEvents = !shouldAcceptEvents
        if window.ignoresMouseEvents != shouldIgnoreEvents {
            window.ignoresMouseEvents = shouldIgnoreEvents
        }
    }

    func showWindow() {
        guard !window.isVisible else { return }
        centerOnActiveScreen()
        
        window.orderFront(nil)
    }

    func hideWindow() {
    }

    private func centerOnActiveScreen() {
        let screen = screenWithMouse()
        let currentWidth = window.frame.width
        let x = screen.frame.midX - (currentWidth / 2)
        let y = screen.visibleFrame.minY + 4
        let nextOrigin = NSPoint(x: x, y: y)
        currentScreen = screen

        let currentOrigin = window.frame.origin
        guard abs(currentOrigin.x - nextOrigin.x) > 0.5 || abs(currentOrigin.y - nextOrigin.y) > 0.5 else {
            return
        }

        window.setFrameOrigin(nextOrigin)
    }

    private func screenWithMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }
}
