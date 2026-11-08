import AppKit
import ChelkaCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windowController: NotchWindowController!
    private var model: NotchModel!
    private var preferences: Preferences!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.chelka.lab")
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if existing != nil { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chelka", isDirectory: true)
        preferences = Preferences()
        let shelf = ShelfModel(root: root)
        model = NotchModel(shelf: shelf, preferences: preferences)
        windowController = NotchWindowController(model: model)
        setupStatusItem()
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenu.addItem(item("Выйти из Чёлки", action: #selector(quit), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
        Task { await shelf.load() }
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Чёлка")
            button.image?.isTemplate = true
            button.toolTip = "Чёлка — файловая полка"
        }
        let menu = NSMenu()
        menu.addItem(item("Открыть Чёлку", action: #selector(openNotch), key: "o"))
        menu.addItem(item("Файловая полка", action: #selector(openShelf), key: "f"))
        menu.addItem(.separator())
        menu.addItem(item("Настройки…", action: #selector(openPreferences), key: ","))
        menu.addItem(item("Показать локальное хранилище", action: #selector(showStorage)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "Чёлка 0.3.2", action: nil, keyEquivalent: "")
        version.isEnabled = false; menu.addItem(version)
        menu.addItem(item("Выйти из Чёлки", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }
    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    @objc private func openNotch() { windowController.open() }
    @objc private func openShelf() { windowController.open(.shelf) }
    @objc private func openPreferences() { windowController.open(.preferences) }
    @objc private func showStorage() { NSWorkspace.shared.open(model.shelf.repository.root) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { windowController?.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { windowController?.open(); return true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
