import AppKit
import Combine
import ForelockMusic

@MainActor final class MusicCoordinator: ObservableObject {
    @Published private(set) var registry = MusicRegistry()
    @Published private(set) var updates: [String: ProviderUpdate] = [:]
    @Published private(set) var busy = false
    @Published private(set) var commandError: String?
    @Published private(set) var yandexEnabled = false
    private let apple = AppleMusicProvider()
    private let browser = BrowserMusicProvider()
    private let yandex = YandexDesktopMusicProvider()
    private var preferenceSubscription: AnyCancellable?
    private var tasks: [Task<Void, Never>] = []
    var selected: MusicSnapshot? { registry.selected }
    var sources: [MusicSnapshot] { registry.sources.values.sorted { $0.id < $1.id } }
    var appleState: ProviderState { updates["apple"]?.state ?? .notRunning }
    var yandexConflicts: Bool {
        NowPlayingTransportPolicy.blocked(updates["yandex-desktop"]?.snapshots.first, by: updates.filter { $0.key != "yandex-desktop" }.values.flatMap(\.snapshots))
    }
    var yandexControlNotice: String {
        yandexConflicts ? "Другой плеер воспроизводит музыку. Управление Яндексом заблокировано." : "Эксперимент: команды идут текущему системному плееру. Проверка источника не атомарна — между проверкой и отправкой возможна смена плеера."
    }
    func start(preferences: Preferences) {
        guard tasks.isEmpty else { return }
        preferenceSubscription = preferences.$experimentalYandexEnabled.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            self.yandexEnabled = enabled
            Task { await self.yandex.setEnabled(enabled) }
        }
        Task { await browser.start() }
        for provider: any MusicProvider in [apple, browser, yandex] {
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    let update = await provider.poll()
                    guard !Task.isCancelled, let self else { return }
                    self.apply(provider.providerID, update)
                    try? await Task.sleep(for: .seconds(1))
                }
            })
        }
    }
    func stop() { preferenceSubscription = nil; yandex.stopImmediately(); tasks.forEach { $0.cancel() }; tasks.removeAll(); Task { await yandex.setEnabled(false); await browser.stop() } }
    private func apply(_ id: String, _ update: ProviderUpdate) {
        let oldSelection = registry.selectedID
        updates[id] = update
        if id != "yandex-desktop" { registry.apply(provider: id, update: update, now: Date()) }
        if let source = updates["yandex-desktop"] {
            let safe = ProviderUpdate(source.snapshots.map { yandexConflicts ? $0.withCommands([]) : $0 }, state: source.state, detail: source.detail)
            registry.apply(provider: "yandex-desktop", update: safe, now: Date())
        }
        if registry.selectedID != oldSelection { commandError = nil }
    }
    func select(_ id: String?) { registry.select(id); commandError = nil }
    func authorizeAppleMusic() {
        guard !busy else { return }
        busy = true
        Task {
            let state = await apple.requestAuthorization()
            updates["apple"] = ProviderUpdate(state: state)
            busy = false
        }
    }
    func send(_ command: MusicCommand, position: Double? = nil) {
        guard !busy, let selected, selected.commands.contains(command) else { return }
        busy = true; commandError = nil
        let provider: any MusicProvider
        switch selected.service { case .appleMusic: provider = apple; case .yandexDesktop: provider = yandex; case .yandexChrome, .zvukChrome: provider = browser }
        Task {
            do {
                guard registry.selected?.id == selected.id, registry.selected?.commands.contains(command) == true,
                      selected.service != .yandexDesktop || (!yandexConflicts && registry.selected?.commandGeneration == selected.commandGeneration) else { throw MusicIntegrationError.unavailable }
                try await provider.perform(command, snapshot: selected, position: position)
            }
            catch { if registry.selectedID == selected.id { commandError = error.localizedDescription } }
            let update = await provider.poll()
            apply(provider.providerID, update)
            busy = false
        }
    }
}
