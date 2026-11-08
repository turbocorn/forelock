import AppKit
import SwiftUI
import ChelkaCore

// One surface, no independent notification windows.
enum NotchState: Equatable {
    case idle, hover, overview, shelf, preview(UUID), preferences
    var isOpen: Bool { self != .idle }
    var isExpanded: Bool { self != .idle && self != .hover }
    var interactionMode: NotchInteractionMode { self == .idle ? .idle : self == .hover ? .hover : .expanded }
}

struct MusicSnapshot {
    let title: String
    let artist: String
    let isPlaying: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
}
@MainActor protocol MusicProvider: AnyObject { var currentTrack: MusicSnapshot? { get } }
@MainActor final class UnconnectedMusicProvider: MusicProvider { let currentTrack: MusicSnapshot? = nil }

struct Activity: Identifiable { let id: UUID; let title: String; let detail: String }
@MainActor protocol ActivityProvider: AnyObject { var activities: [Activity] { get } }
/// Intentionally empty until a real source is connected.
@MainActor final class UnconnectedActivityProvider: ActivityProvider { let activities: [Activity] = [] }

@MainActor final class NotchModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published var surfaceSize = CGSize(width: 236, height: 46)
    @Published var geometry: NotchGeometry?
    @Published var magnetic = false
    @Published var attraction: CGFloat = 0
    @Published var fullscreen = false
    @Published var isInteracting = false
    @Published var draggingOut = false
    @Published var error: String?
    @Published var importedMessage: String?
    let shelf: ShelfModel
    let preferences: Preferences
    let activity: any ActivityProvider
    let music: any MusicProvider
    var onTransition: ((NotchState, NotchState, String) -> Void)?
    var requestKey: (() -> Void)?

    init(shelf: ShelfModel, preferences: Preferences) {
        self.shelf = shelf
        self.preferences = preferences
        self.activity = UnconnectedActivityProvider()
        self.music = UnconnectedMusicProvider()
    }

    var headerHeight: CGFloat { geometry?.headerHeight ?? 38 }
    var contentTop: CGFloat { headerHeight + 31 }
    var expandedWidth: CGFloat { geometry?.expandedWidth ?? 900 }
    var bodyHeight: CGFloat { targetSize.height - contentTop - 24 - (shelf.error == nil ? 0 : 30) }
    var targetSize: CGSize {
        let top = headerHeight
        let compactWidth = geometry?.hoverWidth ?? 420
        if magnetic { return CGSize(width: compactWidth + abs(attraction) * 0.3, height: top + 122) }
        switch state {
        case .idle: return geometry?.idleSize ?? CGSize(width: 220, height: 38)
        case .hover: return CGSize(width: compactWidth, height: top + 102)
        case .overview, .shelf: return CGSize(width: expandedWidth, height: top + 212 + (shelf.error == nil ? 0 : 30))
        case .preview: return CGSize(width: expandedWidth, height: top + 272)
        case .preferences: return CGSize(width: expandedWidth, height: top + 252)
        }
    }
    var reduceMotion: Bool { preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func open(_ destination: NotchState = .overview, byHover: Bool = false, reason: String = "explicit-open") {
        error = nil
        // SurfaceSpring owns geometry. A second implicit SwiftUI frame animation
        // would lag behind NSPanel and detach the mask during expansion.
        transition(to: byHover ? .hover : destination, reason: byHover ? "hover-dwell" : reason)
        if state.isOpen { requestKey?() }
    }
    @discardableResult func close(reason: String = "close-button") -> Bool {
        guard !isInteracting && !draggingOut else { return false }
        magnetic = false; attraction = 0
        transition(to: .idle, reason: reason)
        return true
    }
    private func transition(to next: NotchState, reason: String) {
        guard state != next else { return }
        let previous = state
        state = next
        onTransition?(previous, next, reason)
    }
    func importFiles(_ urls: [URL], reason: String = "file-import") {
        magnetic = false
        attraction = 0
        open(.shelf, reason: reason)
        Task {
            isInteracting = true
            await shelf.importFiles(urls)
            isInteracting = false
        }
    }
    func saveCopy(of item: ShelfItem) {
        isInteracting = true
        let picker = NSSavePanel()
        picker.title = "Сохранить копию"
        picker.prompt = "Сохранить"
        picker.nameFieldStringValue = item.name
        picker.canCreateDirectories = true
        picker.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = picker.url else { self.isInteracting = false; self.requestKey?(); return }
            let source = self.shelf.url(for: item)
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: source, to: destination) }.value
                    self.error = nil
                } catch { self.error = "Не удалось сохранить копию: \(error.localizedDescription)" }
                self.isInteracting = false
                self.requestKey?()
            }
        }
    }
    func chooseFiles() {
        isInteracting = true
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.title = "Добавить на полку"
        picker.prompt = "На полку"
        picker.message = "Чёлка сохранит отдельные локальные копии. Оригиналы останутся на месте."
        picker.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self else { return }
            self.isInteracting = false
            if response == .OK { self.importFiles(picker.urls) }
            else { self.requestKey?() }
        }
    }
}
