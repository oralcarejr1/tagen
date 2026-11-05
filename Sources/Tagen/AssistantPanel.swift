#if os(macOS)
import AppKit
import SwiftUI

/// Compact floating assistant: a non-activating panel that can take keyboard focus
/// (so typing works) without bringing Tagen's other windows forward.
final class AssistantPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 420, height: 320)
        sharingType = .none   // never captured into Tagen's own screenshots
        let host = NSHostingView(rootView: content)
        contentView = host
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// Place near the top-center of the screen containing the mouse.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 60))
    }
}
#endif
