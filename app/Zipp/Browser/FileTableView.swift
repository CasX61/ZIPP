import AppKit

/// Tabelle mit WinRAR-/Finder-Tastatursteuerung.
final class FileTableView: NSTableView {
    var onQuickLook: (() -> Void)?
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onDelete: (() -> Void)?
    var contextMenuProvider: ((_ row: Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 49 where flags.isEmpty: // Leertaste
            onQuickLook?()
        case 36 where flags.isEmpty, 76 where flags.isEmpty: // Return, Enter
            onOpen?()
        case 125 where flags == .command: // ⌘↓
            onOpen?()
        case 126 where flags == .command: // ⌘↑
            onGoUp?()
        case 51 where flags == .command, 117 where flags.isEmpty: // ⌘⌫, Entf
            onDelete?()
        case 51 where flags.isEmpty: // ⌫ = eine Ebene hoch (wie bei WinRAR)
            onGoUp?()
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?(row)
    }
}

/// Balken für die Ersparnis in der Tabelle.
final class RatioBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var isEmphasized = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 5) / 2, width: bounds.width, height: 5)
        let trackColor = isEmphasized ? NSColor.white.withAlphaComponent(0.3) : NSColor.quaternaryLabelColor
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        guard fraction > 0 else { return }
        var bar = track
        bar.size.width = max(3, track.width * min(1, fraction))
        (isEmphasized ? NSColor.white : NSColor.systemGreen).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

/// Zelle „Ersparnis“: Balken + Prozent.
final class RatioCellView: NSTableCellView {
    let bar = RatioBarView()
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        addSubview(bar)
        addSubview(label)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 46),
            bar.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { bar.isEmphasized = backgroundStyle == .emphasized }
    }
}
