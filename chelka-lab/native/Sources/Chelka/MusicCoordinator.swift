import AppKit
import ForelockMusic

@MainActor final class MusicCoordinator: ObservableObject {
    @Published private(set) var registry = MusicRegistry()
    @Published private(set) var updates: [String: ProviderUpdate] = [:]
    @Published private(set) var busy = false
    @Published private(set) var commandError: String?
    private let apple = AppleMusicProvider()
    private let browser = BrowserMusicProvider()
    private var tasks: [Task<Void, Never>] = []
    var selected: MusicSnapshot? { registry.selected }
    var sources: [MusicSnapshot] { registry.sources.values.sorted { $0.id < $1.id } }
    var appleState: ProviderState { updates["apple"]?.state ?? .notRunning }
    func start() {
        guard tasks.isEmpty else { return }
        Task { await browser.start() }
        for provider: any MusicProvider in [apple, browser] {
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    let update = await provider.poll()
                    guard !Task.isCancelled, let self else { return }
                    self.updates[provider.providerID] = update
                    self.registry.apply(provider: provider.providerID, update: update, now: Date())
                    try? await Task.sleep(for: .seconds(1))
                }
            })
        }
    }
    func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll(); Task { await browser.stop() } }
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
        let provider: any MusicProvider = selected.service == .appleMusic ? apple : browser
        Task {
            do { try await provider.perform(command, sourceID: selected.id, position: position) }
            catch { commandError = error.localizedDescription }
            let update = await provider.poll()
            updates[provider.providerID] = update
            registry.apply(provider: provider.providerID, update: update, now: Date())
            busy = false
        }
    }
}
