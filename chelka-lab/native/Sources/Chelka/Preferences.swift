import Foundation
import ServiceManagement
import SwiftUI
import ChelkaCore

@MainActor final class Preferences: ObservableObject {
    @Published var hoverEnabled: Bool { didSet { defaults.set(hoverEnabled, forKey: "hoverEnabled") } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var allowFullscreen: Bool { didSet { defaults.set(allowFullscreen, forKey: "allowFullscreen") } }
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "reduceMotion") } }
    @Published var experimentalYandexEnabled: Bool { didSet { defaults.set(experimentalYandexEnabled, forKey: "experimentalYandexEnabled") } }
    @Published var liveLeft: LiveSlotChoice { didSet { defaults.set(liveLeft.rawValue, forKey: "liveLeft") } }
    @Published var liveRight: LiveSlotChoice { didSet { defaults.set(liveRight.rawValue, forKey: "liveRight") } }
    @Published var allowLiveFullscreen: Bool { didSet { defaults.set(allowLiveFullscreen, forKey: "allowLiveFullscreen") } }
    @Published private(set) var launchAtLogin = false
    @Published var loginMessage: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverEnabled = defaults.object(forKey: "hoverEnabled") as? Bool ?? true
        hoverDelay = defaults.object(forKey: "hoverDelay") as? Double ?? 0.32
        allowFullscreen = defaults.object(forKey: "allowFullscreen") as? Bool ?? false
        reduceMotion = defaults.bool(forKey: "reduceMotion")
        experimentalYandexEnabled = defaults.object(forKey: "experimentalYandexEnabled") as? Bool ?? true
        liveLeft = LiveSlotChoice(rawValue: defaults.string(forKey: "liveLeft") ?? "") ?? .auto
        liveRight = LiveSlotChoice(rawValue: defaults.string(forKey: "liveRight") ?? "") ?? .auto
        allowLiveFullscreen = defaults.bool(forKey: "allowLiveFullscreen")
        refreshLoginStatus()
    }

    func refreshLoginStatus() { launchAtLogin = SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ value: Bool) {
        loginMessage = nil
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
            if SMAppService.mainApp.status == .requiresApproval {
                loginMessage = "Разрешите запуск в Системных настройках → Основные → Объекты входа."
            }
        } catch {
            refreshLoginStatus()
            loginMessage = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
    }
}
