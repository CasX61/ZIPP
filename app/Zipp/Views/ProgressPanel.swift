import AppKit
import SwiftUI

/// Kleines schwebendes Fortschrittsfenster (z. B. beim Herausziehen in den Finder).
///
/// Es aktiviert ZIPP nicht und bleibt sichtbar, auch wenn danach der Finder vorne
/// ist. Der Inhalt ist dieselbe `JobView` wie im Archivfenster.
@MainActor
final class ProgressPanel {
    /// Platz um die Karte herum, damit ihr Schatten nicht abgeschnitten wird.
    private static let margin: CGFloat = 24

    private let panel: NSPanel

    init(job: Job) {
        let hosting = FirstMouseHostingView(
            rootView: JobView(job: job)
                .frame(width: 420)
                .padding(Self.margin)
        )
        hosting.setFrameSize(hosting.fittingSize)

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.title = job.title
        panel.setAccessibilityRole(.window)
    }

    /// Unten mittig über dem Archivfenster, sonst mittig auf dem Hauptbildschirm.
    func show(near window: NSWindow?) {
        let size = panel.frame.size
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        if let frame = window?.frame, window?.isVisible == true {
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 40)
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}

/// Der Abbrechen-Knopf soll schon beim ersten Klick reagieren, auch wenn
/// gerade eine andere App (meist der Finder) aktiv ist.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
