import AppKit

// AppKit-Lebenszyklus (ohne Storyboard): Menüs und Fenster baut der AppDelegate.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
