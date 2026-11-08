import AppKit
import SwiftUI
import ChelkaCore
import Combine

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
private enum ShelfSelectionContext: Equatable { case full, recent(UUID) }
@MainActor protocol ActivityProvider: AnyObject { var activities: [Activity] { get } }
/// Intentionally empty until a real source is connected.
@MainActor final class UnconnectedActivityProvider: ActivityProvider { let activities: [Activity] = [] }

@MainActor final class NotchModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published var surfaceSize = CGSize(width: 236, height: 46)
    @Published var surfaceInsets=CGSize.zero
    @Published private(set) var liveDisplay=LiveSurfacePlan.empty
    @Published private(set) var liveDisplayOpacity=0.0
    @Published var liveHandoff=false
    private var contentFade=SurfaceContentFade()
    @Published var geometry: NotchGeometry?
    @Published private(set) var fileDrop: FileDropStatus?
    @Published private(set) var recentDrop: RecentFileDrop?
    @Published private(set) var selection = ShelfSelection()
    @Published private(set) var selectionError: String?
    @Published private(set) var selectionMessage: String?
    @Published var shelfPointerInteracting = false
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
    let deviceEvents: DeviceEventAdapter
    let liveSurface: LiveSurfaceCoordinator
    var onTransition: ((NotchState, NotchState, String) -> Void)?
    var requestKey: (() -> Void)?
    var requestShelfFocus: (() -> Void)?
    private var shelfChanges: AnyCancellable?
    private var selectionContext: ShelfSelectionContext?
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
    var activeShelfItems: [ShelfItem] {
        guard !magnetic else { return [] }
        if state == .shelf { return shelf.items }
        if isMiniShelf { return recentItems }
        return []
    }
    var hasShelfSelection: Bool { !selection.ids.isEmpty && (state == .shelf || isMiniShelf) && !magnetic }
    var canUseShelfKeyboard: Bool { !magnetic && (state == .shelf || isMiniShelf) }

    init(shelf: ShelfModel, preferences: Preferences) {
        self.shelf = shelf
        self.preferences = preferences
        self.activity = UnconnectedActivityProvider()
        self.music = MusicCoordinator()
        self.liveSurface = LiveSurfaceCoordinator(music: music, shelf: shelf, preferences: preferences)
        self.deviceEvents = DeviceEventAdapter(live:liveSurface)
        liveSurface.performAction = { [weak self] action in
            switch action { case .openShelf: self?.open(.shelf, reason: "live-surface-action") }
        }
        shelfChanges = shelf.$items.sink { [weak self] items in
            guard let self else { return }
            var next = self.selection; next.reconcile(items.map(\.id))
            if next != self.selection { self.selection = next }
        }
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
        case .idle: return liveSurface.plan.footprint(geometry).size
        case .hover: return CGSize(width: compactWidth, height: top + 102)
        case .miniShelf: return FileDropLayout.surfaceSize(geometry)
        case .overview, .shelf: return CGSize(width: expandedWidth, height: top + 212 + (shelf.error == nil ? 0 : 30))
        case .preview: return CGSize(width: expandedWidth, height: top + 272)
        case .preferences: return CGSize(width: expandedWidth, height: top + 252)
        }
    }
    var targetInsets:CGSize {state == .idle && !magnetic ? liveSurface.plan.footprint(geometry).insets : .zero}
    var paintedBounds:CGRect {LiveSurfaceLayout.paintedRect(in:surfaceSize,insets:surfaceInsets,cameraWidth:geometry?.hasNotch == false ? 0 : geometry?.neckWidth ?? 220)}
    var workspaceHeaderOpacity:Double {
        guard liveHandoff,!reduceMotion else{return 1}
        let camera=geometry?.hasNotch == false ? 0 : (geometry?.neckWidth ?? 220)+24
        let required:CGFloat=state.isExpanded ? 210 : 70
        let side=max(0,(surfaceSize.width-camera)/2)
        let t=Double(min(1,max(0,(side/required-0.75)/0.25)))
        return t*t*(3-2*t)*(1-liveDisplayOpacity)
    }
    func advanceLiveContent(dt:Double) {
        let wanted=state == .idle && !magnetic ? liveSurface.plan : LiveSurfacePlan.empty
        if magnetic || draggingOut {
            contentFade.snap(to:nil)
            if liveDisplay != .empty {liveDisplay = .empty}
            if liveDisplayOpacity != 0 {liveDisplayOpacity=0}
            return
        }
        if wanted == liveDisplay,liveDisplayOpacity == (wanted.visualKey == nil ? 0 : 1) {return}
        if liveDisplayOpacity==1,wanted.isValueUpdate(from:liveDisplay) {contentFade.snap(to:wanted.visualKey)}
        contentFade.request(wanted.visualKey)
        _=contentFade.step(dt:dt,ready:wanted.ready(size:surfaceSize,painted:paintedBounds,geometry:geometry),reduced:reduceMotion)
        if contentFade.key == wanted.visualKey,liveDisplay != wanted {liveDisplay=wanted}
        if liveDisplayOpacity != contentFade.opacity {liveDisplayOpacity=contentFade.opacity}
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
        reconcileSelectionContext()
        onTransition?(previous, next, reason)
    }
    private func reconcileSelectionContext() {
        if case .preview = state { return }
        if state == .shelf { selectionContext = .full; selection.reconcile(shelf.items.map(\.id)) }
        else if state == .miniShelf, let result = recentDrop {
            let context = ShelfSelectionContext.recent(result.id)
            if selectionContext != context { selection.clear() }
            selectionContext = context; selection.reconcile(recentItems.map(\.id))
        } else { selectionContext = nil; selection.clear() }
        selectionError = nil; selectionMessage = nil
        shelfPointerInteracting = false
    }
    func shelfClick(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        guard canUseShelfKeyboard, !isInteracting, !draggingOut, !shelf.loading else { return }
        let ordered = activeShelfItems.map(\.id)
        guard ordered.contains(id) else { return }
        selectionMessage = nil
        if modifiers.contains(.shift), state == .shelf {
            selection.range(to: id, ordered: ordered, additive: modifiers.contains(.command))
        } else if modifiers.contains(.command) { selection.toggle(id, ordered: ordered) }
        else if modifiers.contains(.shift) { selection.clear(); selection.toggle(id, ordered: ordered) }
        else {
            selection.plainClick(id)
            if isMiniShelf { openRecentFile(id) } else { openPreview(id) }
        }
    }
    func selectAllShelfFiles() {
        guard canUseShelfKeyboard, !isInteracting, !draggingOut, !shelf.loading else { return }
        selection.selectAll(activeShelfItems.map(\.id)); selectionMessage = nil
    }
    @discardableResult func clearShelfSelection() -> Bool {
        guard hasShelfSelection, !draggingOut, !isInteracting else { return false }
        selection.clear(); selectionError = nil; return true
    }
    func shelfDragItems(from id: UUID) -> [ShelfItem] {
        guard !isInteracting, !draggingOut, !shelf.loading else { return [] }
        let items = activeShelfItems
        let ids = Set(selection.dragIDs(from: id, ordered: items.map(\.id)))
        return items.filter { ids.contains($0.id) }
    }
    func deleteSelectedCopies() {
        guard hasShelfSelection, !isInteracting, !draggingOut, !shelf.loading else { return }
        let ids = selection.ids
        isInteracting = true; selectionError = nil
        Task {
            let removed = await shelf.removeCopies(ids: ids)
            selection.reconcile(activeShelfItems.map(\.id))
            selectionError = shelf.error
            selectionMessage = "Удалено: \(fileCount(removed.count))"
            isInteracting = false
            requestShelfFocus?()
        }
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
        selection.plainClick(id)
        open(.preview(id), reason: "recent-file-preview")
    }
    func openPreview(_ id: UUID) {
        selection.plainClick(id)
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
