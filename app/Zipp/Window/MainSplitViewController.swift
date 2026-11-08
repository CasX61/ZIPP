import AppKit
import SwiftUI

/// Seitenleiste | Dateiliste | Inspektor
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let session: ArchiveSession
    let browser: BrowserViewController
    private let onOpenRecent: (URL) -> Void
    private let onQuickExtract: (URL) -> Void

    init(session: ArchiveSession, onOpenRecent: @escaping (URL) -> Void, onQuickExtract: @escaping (URL) -> Void) {
        self.session = session
        self.browser = BrowserViewController(session: session)
        self.onOpenRecent = onOpenRecent
        self.onQuickExtract = onQuickExtract
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarHost = NSHostingController(rootView: SidebarView(
            session: session,
            onOpenRecent: onOpenRecent,
            onQuickExtract: onQuickExtract
        ))
        sidebarHost.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 340
        sidebar.canCollapse = true

        let content = NSSplitViewItem(viewController: browser)
        content.minimumThickness = 380

        let inspectorHost = NSHostingController(rootView: InspectorView(session: session))
        inspectorHost.sizingOptions = []
        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspector.minimumThickness = 240
        inspector.maximumThickness = 380
        inspector.canCollapse = true

        addSplitViewItem(sidebar)
        addSplitViewItem(content)
        addSplitViewItem(inspector)
        splitView.autosaveName = "ZIPPMainSplit"
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(browser.tableView)
    }
}
