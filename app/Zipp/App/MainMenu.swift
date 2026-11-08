import AppKit

/// Hauptmenü (deutsch). Aktionen ohne Ziel laufen über die Responder-Kette,
/// landen also beim Fenster-Controller des aktiven Fensters.
@MainActor
enum MainMenu {
    static func build(recentMenuDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("ZIPP", appMenu()))
        main.addItem(submenu("Ablage", fileMenu(recentMenuDelegate: recentMenuDelegate)))
        main.addItem(submenu("Bearbeiten", editMenu()))
        main.addItem(submenu("Darstellung", viewMenu()))
        main.addItem(submenu("Archiv", archiveMenu()))
        let window = windowMenu()
        main.addItem(submenu("Fenster", window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu("Hilfe", help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        symbol: String? = nil,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        let delegate = NSApp.delegate
        menu.addItem(item("Über ZIPP", #selector(AppDelegate.showAbout(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Nach Updates suchen …", #selector(AppDelegate.checkForUpdates(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Einstellungen …", #selector(AppDelegate.showSettings(_:)), ",", target: delegate))
        menu.addItem(.separator())
        let services = NSMenu()
        menu.addItem(submenu("Dienste", services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("ZIPP ausblenden", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("ZIPP beenden", #selector(AppDelegate.quit(_:)), "q", target: delegate))
        return menu
    }

    private static func fileMenu(recentMenuDelegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu()
        let delegate = NSApp.delegate
        menu.addItem(item("Neues Archiv …", #selector(AppDelegate.newDocument(_:)), "n", symbol: "plus.rectangle.on.folder", target: delegate))
        menu.addItem(item("Neues Fenster", #selector(AppDelegate.newWindow(_:)), "n", [.command, .option], target: delegate))
        menu.addItem(item("Öffnen …", #selector(AppDelegate.openDocument(_:)), "o", symbol: "folder", target: delegate))
        let recent = NSMenu()
        recent.delegate = recentMenuDelegate
        menu.addItem(submenu("Zuletzt geöffnet", recent))
        menu.addItem(.separator())
        menu.addItem(item("Archiv im Finder zeigen", #selector(ArchiveWindowController.revealArchive(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Fenster schließen", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Widerrufen", Selector(("undo:")), "z"))
        menu.addItem(item("Wiederholen", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Ausschneiden", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Kopieren", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Einsetzen", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Alles auswählen", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Im Archiv suchen", #selector(ArchiveWindowController.focusSearch(_:)), "f", symbol: "magnifyingglass"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Seitenleiste ein-/ausblenden", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Inspektor ein-/ausblenden", #selector(NSSplitViewController.toggleInspector(_:)), "i"))
        menu.addItem(.separator())
        let appearance = NSMenu()
        for option in AppAppearance.allCases {
            let entry = item(option.title, #selector(AppDelegate.chooseAppearance(_:)), symbol: option.symbol, target: NSApp.delegate)
            entry.representedObject = option.rawValue
            appearance.addItem(entry)
        }
        let appearanceItem = submenu("Erscheinungsbild", appearance)
        appearanceItem.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        menu.addItem(appearanceItem)
        menu.addItem(.separator())
        menu.addItem(item("Symbolleiste anpassen …", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(item("Vollbild", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func archiveMenu() -> NSMenu {
        let menu = NSMenu()
        typealias W = ArchiveWindowController
        menu.addItem(item("Entpacken", #selector(W.extractDefault(_:)), "e", symbol: "arrow.down.doc"))
        menu.addItem(item("Entpacken nach …", #selector(W.extractTo(_:)), "e", [.command, .option]))
        menu.addItem(item("Archiv testen", #selector(W.testArchive(_:)), "t", symbol: "checkmark.shield"))
        menu.addItem(.separator())
        menu.addItem(item("Dateien hinzufügen …", #selector(W.addFiles(_:)), "a", [.command, .shift], symbol: "plus"))
        menu.addItem(item("Neuer Ordner …", #selector(W.newFolder(_:)), "n", [.command, .shift], symbol: "folder.badge.plus"))
        // F2 wie bei WinRAR und im Windows-Explorer
        menu.addItem(item("Umbenennen …", #selector(W.renameSelection(_:)), functionKey(NSF2FunctionKey), [], symbol: "pencil"))
        menu.addItem(item("Aus Archiv löschen", #selector(W.deleteSelection(_:)), "\u{8}", symbol: "trash"))
        menu.addItem(.separator())
        menu.addItem(item("Konvertieren …", #selector(W.convertArchive(_:)), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        menu.addItem(item("Öffnen", #selector(W.openSelection(_:)), arrowKey(NSDownArrowFunctionKey)))
        menu.addItem(item("Quick Look (Leertaste)", #selector(W.toggleQuickLook(_:)), symbol: "eye"))
        menu.addItem(item("Übergeordneter Ordner", #selector(W.goUp(_:)), arrowKey(NSUpArrowFunctionKey)))
        menu.addItem(item("Zurück", #selector(W.goBack(_:)), "["))
        menu.addItem(item("Vor", #selector(W.goForward(_:)), "]"))
        menu.addItem(.separator())
        menu.addItem(item("Passwort eingeben …", #selector(W.unlockArchive(_:))))
        return menu
    }

    private static func functionKey(_ key: Int) -> String { arrowKey(key) }

    private static func arrowKey(_ key: Int) -> String {
        UnicodeScalar(UInt32(key)).map { String(Character($0)) } ?? ""
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoomen", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Alle nach vorne bringen", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("ZIPP im Finder-Kontextmenü …", #selector(AppDelegate.openServicesHelp(_:)), target: NSApp.delegate))
        menu.addItem(item("ZIPP auf GitHub", #selector(AppDelegate.openProjectPage(_:)), target: NSApp.delegate))
        return menu
    }
}
