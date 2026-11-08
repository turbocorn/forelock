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
        model.music.start(preferences: preferences)
        model.deviceEvents.start()
        setupStatusItem()
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenu.addItem(item("Выйти из Forelock", action: #selector(quit), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
        Task { await shelf.load() }
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Forelock")
            button.image?.isTemplate = true
            button.toolTip = "Forelock — файловая полка"
        }
        let menu = NSMenu()
        menu.addItem(item("Открыть Forelock", action: #selector(openNotch), key: "o"))
        menu.addItem(item("Файловая полка", action: #selector(openShelf), key: "f"))
        menu.addItem(.separator())
        menu.addItem(item("Настройки…", action: #selector(openPreferences), key: ","))
        menu.addItem(item("Показать локальное хранилище", action: #selector(showStorage)))
#if DEBUG
        let diagnostics=NSMenuItem(title:"Live Surface · диагностика",action:nil,keyEquivalent:"")
        let tests=NSMenu()
        for (title,action) in [("Stretch",#selector(testStretch)),("Peek",#selector(testPeek)),("Приоритет P1 поверх P2",#selector(testPriorities)),("Три повтора Stretch",#selector(testDuplicates)),("Индикатор внимания",#selector(testAttention)),("Очистить диагностику",#selector(clearDiagnostics))] {
            tests.addItem(item(title,action:action))
        }
        diagnostics.submenu=tests;menu.addItem(diagnostics)
#endif
        menu.addItem(.separator())
#if DEBUG
        let version = NSMenuItem(title: "Forelock 0.5.4 · Debug", action: nil, keyEquivalent: "")
#else
        let version = NSMenuItem(title: "Forelock 0.5.4 · эксперимент", action: nil, keyEquivalent: "")
#endif
        version.isEnabled = false; menu.addItem(version)
        menu.addItem(item("Выйти из Forelock", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }
    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
#if DEBUG
    @objc private func testStretch() { model.liveSurface.diagnose(.stretch) }
    @objc private func testPeek() { model.liveSurface.diagnose(.peek) }
    @objc private func testPriorities() { model.liveSurface.diagnose(.priorities) }
    @objc private func testDuplicates() { model.liveSurface.diagnose(.duplicates) }
    @objc private func testAttention() { model.liveSurface.diagnose(.attention) }
    @objc private func clearDiagnostics() { model.liveSurface.diagnose(.clear) }
#endif
    @objc private func openNotch() { windowController.open() }
    @objc private func openShelf() { windowController.open(.shelf) }
    @objc private func openPreferences() { windowController.open(.preferences) }
    @objc private func showStorage() { NSWorkspace.shared.open(model.shelf.repository.root) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.deviceEvents.stop(); model?.music.stop(); windowController?.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { windowController?.open(); return true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
