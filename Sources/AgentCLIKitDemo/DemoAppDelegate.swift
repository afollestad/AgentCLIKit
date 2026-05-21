import AppKit

@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: DemoWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let windowController = DemoWindowController()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        self.windowController = windowController
        activateDemoApp()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)

        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit \(ProcessInfo.processInfo.processName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let newSessionItem = NSMenuItem(title: "New Session", action: #selector(newSession(_:)), keyEquivalent: "n")
        newSessionItem.keyEquivalentModifierMask = .command
        newSessionItem.target = self
        fileMenu.addItem(newSessionItem)
        fileMenuItem.submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func newSession(_ sender: Any?) {
        windowController?.newSession(sender)
    }

    private func activateDemoApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
