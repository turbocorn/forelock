import AppKit
import SwiftUI
import ChelkaCore

// One surface, no independent notification windows.
enum NotchState: Equatable {
    case idle, hover, overview, shelf, miniShelf, preview(UUID), preferences
    var isOpen: Bool { self != .idle }
    var isExpanded: Bool { self != .idle && self != .hover && self != .miniShelf }
    var interactionMode: NotchInteractionMode { self == .idle ? .idle : self == .hover ? .hover : .expanded }
}

struct Activity: Identifiable { let id: UUID; let title: String; let detail: String }
enum FileDropStatus: Equatable {
    case ready(Int), copying(Int)
    var isReady: Bool { if case .ready = self { return true }; return false }
}
/// References the existing Shelf repository; no second set of file data.
struct RecentFileDrop: Identifiable, Equatable {
    let id = UUID()
    let itemIDs: [UUID]
    let attempted: Int
    let error: String?
}
@MainActor protocol ActivityProvider: AnyObject { var activities: [Activity] { get } }
/// Intentionally empty until a real source is connected.
@MainActor final class UnconnectedActivityProvider: ActivityProvider { let activities: [Activity] = [] }

@MainActor final class NotchModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published var surfaceSize = CGSize(width: 236, height: 46)
    @Published var geometry: NotchGeometry?
    @Published private(set) var fileDrop: FileDropStatus?
    @Published private(set) var recentDrop: RecentFileDrop?
    var magnetic: Bool { fileDrop != nil }
    var isMiniShelf: Bool { state == .miniShelf && !magnetic }
    @Published var attraction: CGFloat = 0
    @Published var fullscreen = false
    @Published var isInteracting = false
    @Published var draggingOut = false
    @Published var error: String?
    @Published var importedMessage: String?
    let shelf: ShelfModel
    let preferences: Preferences
    let activity: any ActivityProvider
    let music: MusicCoordinator
    var onTransition: ((NotchState, NotchState, String) -> Void)?
    var requestKey: (() -> Void)?
    private var dropImport: Task<Void, Never>?
    private var dropReturnState: NotchState = .idle
    private var previewReturnState: NotchState = .shelf
    var previewReturnsToMiniShelf: Bool { previewReturnState == .miniShelf && recentDrop != nil }
    var miniShelfReturnsToPinnedContext: Bool { dropReturnState.isExpanded }
    var miniShelfReturnLabel: String {
        switch dropReturnState {
        case .shelf: return "Назад к полке"
        case .overview: return "Назад к обзору"
        case .preview: return "Назад к просмотру"
        case .preferences: return "Назад к настройкам"
        default: return "Назад"
        }
    }
    var recentItems: [ShelfItem] { (recentDrop?.itemIDs ?? []).compactMap { id in shelf.items.first { $0.id == id } } }
    var miniShelfItems: [ShelfItem] { Array(recentItems.prefix(recentItems.count > 4 ? 3 : 4)) }
    var miniShelfOverflow: Int { max(0, recentItems.count - miniShelfItems.count) }

    init(shelf: ShelfModel, preferences: Preferences) {
        self.shelf = shelf
        self.preferences = preferences
        self.activity = UnconnectedActivityProvider()
        self.music = MusicCoordinator()
    }

    var headerHeight: CGFloat { geometry?.headerHeight ?? 38 }
    var contentTop: CGFloat { headerHeight + 31 }
    var expandedWidth: CGFloat { geometry?.expandedWidth ?? 900 }
    var bodyHeight: CGFloat { targetSize.height - contentTop - 24 - (shelf.error == nil ? 0 : 30) }
    var targetSize: CGSize {
        let top = headerHeight
        let compactWidth = geometry?.hoverWidth ?? 420
        if magnetic { return FileDropLayout.surfaceSize(geometry) }
        switch state {
        case .idle: return geometry?.idleSize ?? CGSize(width: 220, height: 38)
        case .hover: return CGSize(width: compactWidth, height: top + 102)
        case .miniShelf: return FileDropLayout.surfaceSize(geometry)
        case .overview, .shelf: return CGSize(width: expandedWidth, height: top + 212 + (shelf.error == nil ? 0 : 30))
        case .preview: return CGSize(width: expandedWidth, height: top + 272)
        case .preferences: return CGSize(width: expandedWidth, height: top + 252)
        }
    }
    var reduceMotion: Bool { preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func open(_ destination: NotchState = .overview, byHover: Bool = false, reason: String = "explicit-open") {
        if destination == .miniShelf && recentDrop == nil { return }
        if destination != .miniShelf {
            if case .preview = destination { /* keep a recent-import preview's return path */ }
            else { recentDrop = nil; previewReturnState = .shelf }
        }
        error = nil
        // SurfaceSpring owns geometry. A second implicit SwiftUI frame animation
        // would lag behind NSPanel and detach the mask during expansion.
        transition(to: byHover ? .hover : destination, reason: byHover ? "hover-dwell" : reason)
        if state.isOpen { requestKey?() }
    }
    @discardableResult func close(reason: String = "close-button") -> Bool {
        guard !isInteracting && !draggingOut && !magnetic else { return false }
        if case .preview = state, previewReturnsToMiniShelf { backFromPreview(); return true }
        recentDrop = nil; previewReturnState = .shelf
        attraction = 0
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
        guard !magnetic else { return }
        attraction = 0
        open(.shelf, reason: reason)
        Task {
            isInteracting = true
            await shelf.importFiles(urls)
            isInteracting = false
        }
    }
    func beginFileDrop(count: Int) {
        guard count > 0, !isInteracting, !draggingOut, !shelf.loading else { return }
        guard fileDrop != .ready(count) else { return }
        if fileDrop == nil && !isMiniShelf && !previewReturnsToMiniShelf { dropReturnState = state }
        fileDrop = .ready(count)
    }
    func cancelFileDrop() {
        guard fileDrop?.isReady == true else { return }
        fileDrop = nil
    }
    /// Capture actual imported IDs; the existing repository still owns copies.
    @discardableResult func acceptFileDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, fileDrop?.isReady == true, !isInteracting, !draggingOut, !shelf.loading else { return false }
        fileDrop = .copying(urls.count)
        isInteracting = true
        let previousIDs = Set(shelf.items.map(\.id))
        dropImport = Task { [weak self] in
            guard let self else { return }
            await self.shelf.importFiles(urls)
            let ids = self.shelf.items.filter { !previousIDs.contains($0.id) }.reversed().map(\.id)
            self.isInteracting = false
            self.recentDrop = RecentFileDrop(itemIDs: ids, attempted: urls.count, error: self.shelf.error)
            self.fileDrop = nil
            // Showing the result must not activate Forelock or steal Finder's focus.
            self.transition(to: .miniShelf, reason: "file-drop-result")
            self.dropImport = nil
        }
        return true
    }
    func openRecentFile(_ id: UUID) {
        guard recentDrop?.itemIDs.contains(id) == true, shelf.items.contains(where: { $0.id == id }) else { return }
        previewReturnState = .miniShelf
        open(.preview(id), reason: "recent-file-preview")
    }
    func openPreview(_ id: UUID) {
        previewReturnState = .shelf; recentDrop = nil
        open(.preview(id))
    }
    func backFromPreview() { open(previewReturnsToMiniShelf ? .miniShelf : .shelf, reason: "preview-back") }
    func dismissMiniShelf(reason: String = "mini-shelf-exit") {
        guard state == .miniShelf, !magnetic, !isInteracting, !draggingOut else { return }
        let destination = dropReturnState.isExpanded ? dropReturnState : .idle
        recentDrop = nil; previewReturnState = .shelf
        transition(to: destination, reason: reason)
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
        picker.message = "Forelock сохранит отдельные локальные копии. Оригиналы останутся на месте."
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
