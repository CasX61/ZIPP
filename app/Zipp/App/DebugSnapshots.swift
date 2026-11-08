#if DEBUG
import AppKit

/// Nur im Debug-Build: rendert Fenster als PNG, z. B. für README-Screenshots
/// oder zum Prüfen des Layouts ohne Bildschirmaufnahme-Berechtigung.
///
///   open -n -a ZIPP.app --env ZIPP_SNAPSHOT_DIR=/tmp/shots --env ZIPP_SNAPSHOT_ACTIONS=folder,extract archiv.zip
///
/// Aktionen (kommagetrennt, nacheinander, je 1,5 s Abstand):
///   select   – erste Datei im aktuellen Ordner auswählen
///   folder   – ersten Ordner öffnen
///   extract  – „Entpacken nach …“-Dialog
///   compress – „Neues Archiv“-Dialog mit dem Archivordner als Quelle
///   extractnow – ganzes Archiv nach ZIPP_SNAPSHOT_DIR/out entpacken
///   test     – Archiv testen
///   rename / newfolder / convert – die jeweiligen Dialoge
///   dorename / dofolder / doconvert – direkt ausführen (erster Eintrag → „Umbenannt“, neuer Ordner, → 7z)
///   dismiss  – offenen Dialog schließen
///   settings – Einstellungen zeigen
///   dark / light – Erscheinungsbild für diesen Lauf (wird nicht gespeichert)
///   service  – Dienst „In eigenen Ordner entpacken“ für das Archiv ausführen
///   welcome  – neues Willkommen-Fenster
///   quit     – App beenden
@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ZIPP_SNAPSHOT_DIR"] else { return }
        let actions = (env["ZIPP_SNAPSHOT_ACTIONS"] ?? "").split(separator: ",").map(String.init)
        Task {
            try? await Task.sleep(for: .seconds(2))
            snapshot(to: dir, name: "00-start")
            for (index, action) in actions.enumerated() {
                perform(action)
                try? await Task.sleep(for: .seconds(1.5))
                snapshot(to: dir, name: String(format: "%02d-%@", index + 1, action))
            }
        }
    }

    private static var controller: ArchiveWindowController? {
        NSApp.orderedWindows.compactMap { $0.windowController as? ArchiveWindowController }.first
    }

    private static func perform(_ action: String) {
        guard let controller else { return }
        let browser = (controller.window?.contentViewController as? MainSplitViewController)?.browser
        switch action {
        case "select":
            if let session = controller.session,
               let file = session.currentFolder?.children.first(where: { !$0.isDirectory }) {
                session.selection = [file]
                browser?.reload()
            }
        case "folder":
            if let session = controller.session,
               let folder = session.currentFolder?.children.first(where: \.isDirectory) {
                session.navigate(to: folder)
            }
        case "extract":
            controller.presentExtractSheet()
        case "compress":
            if let url = controller.archiveURL {
                controller.presentCompress(sources: [url.deletingLastPathComponent()])
            }
        case "extractnow":
            // Ganz normal entpacken, aber in ZIPP_SNAPSHOT_DIR/out
            if let dir = ProcessInfo.processInfo.environment["ZIPP_SNAPSHOT_DIR"] {
                controller.session?.selection = []
                controller.quickExtract(to: URL(fileURLWithPath: dir).appendingPathComponent("out"))
            }
        case "test":
            controller.testArchive(nil)
        case "rename":
            if let session = controller.session, session.selection.count != 1,
               let first = session.currentFolder?.children.first {
                session.selection = [first]
                browser?.reload()
            }
            controller.presentRename()
        case "newfolder":
            controller.presentNewFolder()
        case "convert":
            controller.presentConvert()
        case "dismiss":
            if let content = controller.window?.contentViewController {
                content.presentedViewControllers?.forEach { content.dismiss($0) }
            }
        case "dorename":
            if let session = controller.session, let first = session.currentFolder?.children.first {
                Task { await session.rename(first, to: "Umbenannt") }
            }
        case "dofolder":
            if let session = controller.session {
                Task { await session.createFolder(named: session.suggestedFolderName()) }
            }
        case "doconvert":
            if let session = controller.session {
                let request = CompressRequest(
                    sources: [], name: "konvertiert", folder: session.url.deletingLastPathComponent(),
                    format: .sevenZip, level: 6, password: nil, encryptFileNames: false,
                    excludeMacFiles: false, trashOriginals: false, volumeSize: nil
                )
                Task { await session.convert(request) }
            }
        case "settings":
            AppDelegate.shared?.showSettings(nil)
        case "dark":
            AppAppearance.dark.apply() // nur für diesen Prozess, nicht gespeichert
        case "light":
            AppAppearance.light.apply()
        case "service":
            if let url = controller.archiveURL {
                AppDelegate.shared?.services.extract([url], mode: .always)
            }
        case "welcome":
            AppDelegate.shared?.newWelcomeWindow()
        case "quit":
            AppDelegate.shared?.quit(nil)
        default:
            break
        }
    }

    private static func snapshot(to dir: String, name: String) {
        var windows = NSApp.orderedWindows.filter { $0.isVisible && $0.contentView != nil }
        windows += windows.compactMap(\.attachedSheet)
        for (i, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
