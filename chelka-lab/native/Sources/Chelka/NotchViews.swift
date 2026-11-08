import AppKit
import SwiftUI
import ChelkaCore

extension Color {
    static let chelkaSurface = Color.black
    static let chelkaText = Color(white: 0.95)
    static let chelkaMuted = Color(white: 0.57)
    static let chelkaGreen = Color.white
}

struct NotchSilhouette: Shape {
    let geometry: NotchGeometry?
    func path(in rect: CGRect) -> Path {
        guard let geometry else { return Path(rect) }
        return Path(geometry.outline(for: rect.size))
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var live: LiveSurfaceCoordinator
    init(model:NotchModel,shelf:ShelfModel,preferences:Preferences) {
        self.model=model;self.shelf=shelf;self.preferences=preferences;self.live=model.liveSurface
    }
    private var shape: NotchSilhouette { NotchSilhouette(geometry: model.geometry) }
    private var visibleSurface: Bool {
        let idle = model.geometry?.idleSize ?? CGSize(width: 220, height: 38)
        return model.state.isOpen || model.magnetic || live.presentation.mode == .ambient || live.presentation.mode == .stretch || live.presentation.mode == .peek || model.surfaceSize.width > idle.width + 0.5 || model.surfaceSize.height > idle.height + 0.5
    }
    private var expandedContentOpacity: Double {
        guard !model.reduceMotion else { return 1 }
        let compact = model.geometry?.hoverWidth ?? 420
        return Double(min(1, max(0, (model.surfaceSize.width - compact) / max(1, model.expandedWidth - compact))))
    }
    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(visibleSurface ? Color.black : Color.clear)
            if model.state == .idle && !model.magnetic {
                if live.presentation.mode != .silent && live.presentation.mode != .workspace {
                    LiveSurfaceView(live:live,geometry:model.geometry,size:model.surfaceSize)
                }
                Color.clear.accessibilityElement()
                    .accessibilityLabel("Forelock, свёрнута")
                    .accessibilityAction(named: Text("Раскрыть Forelock")) { model.open() }
                    .accessibilityAction(named: Text("Показать Hover")) { model.open(.hover, reason: "accessibility-hover") }
                    .allowsHitTesting(false)
            } else {
                VStack(spacing: 0) {
                    // One persistent header. Its shoulders track presentation width,
                    // so the camera exclusion stays fixed during an interrupted spring.
                    NotchHeaderRow(model: model, shelf: shelf)
                        .frame(width: model.surfaceSize.width, height: model.headerHeight)
                    if model.isMiniShelf {
                        let rect = FileDropLayout.dropRect(in: model.surfaceSize, headerHeight: model.headerHeight)
                        RecentFilesView(model: model, shelf: shelf).frame(width: rect.width, height: rect.height)
                            .padding(.top, 12)
                    } else if let status = model.fileDrop {
                        let rect = FileDropLayout.dropRect(in: model.surfaceSize, headerHeight: model.headerHeight)
                        MagneticView(status: status).frame(width: rect.width, height: rect.height)
                            .padding(.top, 12)
                    } else if model.state == .hover {
                        MusicHoverView(model: model, shelf: shelf, music: model.music)
                            .frame(width: (model.geometry?.hoverWidth ?? 420) - 40)
                            .padding(.top, 12)
                    } else {
                        ExpandedView(model: model, shelf: shelf, preferences: preferences)
                            .frame(width: model.expandedWidth - 48).opacity(expandedContentOpacity)
                    }
                }
            }
        }
        .frame(width: model.surfaceSize.width, height: model.surfaceSize.height, alignment: .top)
        .transaction { $0.animation = nil }
        .clipShape(shape)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .foregroundStyle(Color.chelkaText)
        .accessibilityIdentifier("ChelkaSurface")
        .modifier(LiveSurfaceDiagnosticActions(live:live))
    }
}

struct NotchHeaderRow: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    private var expanded: Bool { model.state.isExpanded && !model.magnetic }
    private var inShelf: Bool {
        if model.state == .shelf { return true }
        if case .preview = model.state { return true }
        return false
    }
    var body: some View {
        let layout = model.geometry?.headerLayout(for: model.surfaceSize)
        let sideWidth = layout?.left.width ?? model.surfaceSize.width / 2
        let cameraWidth = layout?.camera.width ?? 0
        HStack(spacing: 0) {
            HStack(spacing: 16) {
                if model.isMiniShelf && model.miniShelfReturnsToPinnedContext {
                    icon("arrow.left", label: model.miniShelfReturnLabel) { model.dismissMiniShelf(reason: "recent-back") }
                }
                Text("Forelock").font(.system(size: 14, weight: .semibold))
                if expanded {
                    nav("Обзор", active: model.state == .overview) { model.open(.overview) }
                    nav("Полка", active: inShelf) { model.open(.shelf) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, expanded ? 20 : 12)
            .frame(width: sideWidth, height: model.headerHeight, alignment: .leading)
            .clipped().contentShape(Rectangle())
            Color.clear.frame(width: cameraWidth, height: model.headerHeight)
                .allowsHitTesting(false).accessibilityHidden(true)
            HStack(spacing: 8) {
                if model.isMiniShelf {
                    Button("Все файлы") { model.open(.shelf, reason: "recent-all-files") }
                        .font(.system(size: 11)).foregroundStyle(Color.chelkaMuted).buttonStyle(.plain)
                        .frame(minHeight: 28).accessibilityLabel("Все файлы")
                } else if model.magnetic {
                    Text("Полка").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
                } else if expanded {
                    if shelf.loading { ProgressView().controlSize(.small).accessibilityLabel("Копирование файлов") }
                    else if case .preview = model.state {
                        headerAction(model.previewReturnsToMiniShelf ? "К добавленным" : "Назад к полке", symbol: "arrow.left") { model.backFromPreview() }
                    } else {
                        headerAction("Добавить", symbol: "plus") { model.chooseFiles() }
                    }
                    icon("gearshape", label: "Настройки") { model.open(.preferences) }
                } else {
                    icon("arrow.up.left.and.arrow.down.right", label: "Раскрыть обзор") { model.open() }
                }
                if !model.magnetic { icon("xmark", label: "Закрыть Forelock") { model.close() } }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, expanded ? 16 : 12)
            .frame(width: sideWidth, height: model.headerHeight, alignment: .trailing)
            .clipped().contentShape(Rectangle())
        }
        .frame(width: model.surfaceSize.width, height: model.headerHeight)
        .accessibilityIdentifier("ChelkaTopBar")
    }
    private func nav(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : Color.chelkaMuted)
                .frame(minWidth: 48, minHeight: 28)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(Color.white.opacity(0.8)).frame(height: 1) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(text).accessibilityValue(active ? "Выбрано" : "")
    }
    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
    private func headerAction(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 11)); Text(text).font(.system(size: 11)) }
                .foregroundStyle(Color.chelkaMuted).frame(minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(text)
    }
}

struct HoverView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Файловая полка").font(.system(size: 14, weight: .medium))
                Spacer()
                Text(fileCount(shelf.items.count)).font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
            }
            HStack(spacing: 10) {
                if let item = shelf.items.first {
                    Image(nsImage: shelf.image(item)).resizable().scaledToFit().frame(width: 20, height: 20)
                    Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.chelkaMuted)
                } else { Text("Перетащите сюда файл из Finder").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted) }
                Spacer(minLength: 4)
                SurfaceButton("Открыть полку") { model.open(.shelf) }
            }
        }.frame(height: 72)
        .onTapGesture { model.open() }
        .accessibilityIdentifier("ChelkaHover")
    }
}

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var preferences: Preferences
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1).padding(.top, 10).padding(.bottom, 20)
            Group {
                switch model.state {
                case .overview: MusicShelfOverview(model: model, shelf: shelf, music: model.music)
                case .shelf: ShelfView(model: model, shelf: shelf)
                case .preview(let id):
                    if let item = shelf.items.first(where: { $0.id == id }) { FilePreviewView(model: model, shelf: shelf, item: item) }
                    else { ShelfView(model: model, shelf: shelf) }
                case .preferences: PreferencesView(model: model, preferences: preferences)
                case .idle, .hover, .miniShelf: EmptyView()
                }
            }.frame(height: model.bodyHeight, alignment: .top)
            if let error = shelf.error {
                HStack { Text(error).lineLimit(1); Spacer(); SmallIconButton(symbol: "xmark", label: "Закрыть сообщение") { shelf.error = nil } }
                    .font(.system(size: 11)).foregroundStyle(Color.chelkaMuted).padding(.top, 8)
            }
        }.accessibilityIdentifier("ChelkaExpanded")
    }
}

struct OverviewView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Файлы под рукой").font(.system(size: 23, weight: .medium)).tracking(-0.5)
                Text(shelf.items.isEmpty ? "Место для файлов, к которым вы вернётесь." : "\(fileCount(shelf.items.count)) на вашей полке.")
                    .font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineSpacing(3)
                Spacer(minLength: 0)
                SurfaceButton("Открыть полку", prominent: true) { model.open(.shelf) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            SurfaceDivider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Последние файлы").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.chelkaMuted)
                if shelf.items.isEmpty {
                    Text("Пока пусто").font(.system(size: 15, weight: .medium))
                    Text("Файлы появятся здесь после добавления.").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
                } else {
                    ForEach(shelf.items.prefix(3)) { item in
                        Button { model.openPreview(item.id) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: shelf.image(item)).resizable().scaledToFit().frame(width: 26, height: 26)
                                Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }.frame(height: 27).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Просмотреть \(item.name)")
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            SurfaceDivider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Добавить файлы").font(.system(size: 16, weight: .medium))
                Text("Перетащите из Finder\nили выберите с Mac.").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineSpacing(4)
                Spacer(minLength: 0)
                SurfaceButton("Выбрать файлы", symbol: "plus") { model.chooseFiles() }
            }.frame(width: 180, alignment: .leading)
        }
    }
}

struct ShelfView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Group {
                if shelf.items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Полка пока пуста").font(.system(size: 23, weight: .medium)).tracking(-0.5)
                        Text("Оставьте здесь файл из Finder — сохранится отдельная копия.")
                            .font(.system(size: 13)).foregroundStyle(Color.chelkaMuted)
                        Spacer()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), alignment: .leading, spacing: 12) {
                            ForEach(shelf.items) { item in
                                VStack(spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        SelectableShelfTile(model: model, shelf: shelf, item: item)
                                            .frame(height: 91)
                                        Button { shelf.remove(item) } label: {
                                            Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.chelkaMuted)
                                                .frame(width: 25, height: 25).background(Color.black.opacity(0.85), in: Circle())
                                        }.buttonStyle(.plain).disabled(shelf.loading || model.isInteracting || model.draggingOut)
                                            .accessibilityLabel("Удалить \(item.name) с полки").help("Удалить копию с полки. Оригинал останется на месте.")
                                    }
                                    Text(shelf.typeName(item)).font(.system(size: 10)).foregroundStyle(Color.chelkaMuted).lineLimit(1)
                                }
                            }
                        }.padding(.bottom, 6)
                    }.scrollIndicators(.visible)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            SurfaceDivider()
            VStack(alignment: .leading, spacing: 12) {
                if model.hasShelfSelection { ShelfSelectionActions(model: model) }
                else {
                    Text(fileCount(shelf.items.count)).font(.system(size: 18, weight: .medium))
                    Text("Копии хранятся на этом Mac.").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineSpacing(3)
                    Text("⌘ клик — выбрать.\nShift клик — диапазон.\nПотяните, чтобы забрать копии.").font(.system(size: 11)).foregroundStyle(Color.chelkaMuted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                SurfaceButton("Добавить файлы", symbol: "plus") { model.chooseFiles() }.disabled(shelf.loading)
            }.frame(width: 180, alignment: .leading)
        }.background(ShelfFocusRegion().accessibilityHidden(true))
            .simultaneousGesture(TapGesture().onEnded { model.requestShelfFocus?() })
    }
}

struct FilePreviewView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    let item: ShelfItem
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            EmbeddedQuickLook(url: shelf.url(for: item)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            SurfaceDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(.system(size: 16, weight: .medium)).lineLimit(2).truncationMode(.middle)
                Text(shelf.typeName(item)).font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)).font(.system(size: 11)).foregroundStyle(Color.chelkaMuted)
                Spacer(minLength: 0)
                SurfaceButton("Сохранить копию", symbol: "square.and.arrow.down") { model.saveCopy(of: item) }
                HStack {
                    SurfaceButton("В Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([shelf.url(for: item)]) }
                    SurfaceButton("Назад") { model.backFromPreview() }
                }
                if let error = model.error { Text(error).font(.system(size: 10)).foregroundStyle(Color.chelkaMuted).lineLimit(2) }
            }.frame(width: 210, alignment: .leading)
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var preferences: Preferences
    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            ScrollView(.vertical) { VStack(alignment: .leading, spacing: 18) {
                Text("Взаимодействие").font(.system(size: 17, weight: .medium))
                preferenceToggle("Открывать при наведении", isOn: $preferences.hoverEnabled)
                HStack(spacing: 12) {
                    Text("Задержка").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
                    Slider(value: $preferences.hoverDelay, in: 0.2...0.8, step: 0.05).controlSize(.small).tint(.white).disabled(!preferences.hoverEnabled)
                    Text(String(format: "%.2f с", preferences.hoverDelay)).font(.system(size: 11)).foregroundStyle(Color.chelkaMuted).frame(width: 42)
                }
                preferenceToggle("Раскрывать в полноэкранном режиме", isOn: $preferences.allowFullscreen)
                LiveSurfaceSettings(preferences:preferences,devices:model.deviceEvents)
                DeviceSettingsView(devices:model.deviceEvents)
            }.frame(maxWidth: .infinity) }.scrollIndicators(.visible)
            SurfaceDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Приложение").font(.system(size: 17, weight: .medium))
                preferenceToggle("Уменьшить движение", isOn: $preferences.reduceMotion)
                preferenceToggle("Запускать при входе", isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.setLaunchAtLogin($0) }))
                VStack(alignment: .leading, spacing: 5) {
                    preferenceToggle("Яндекс: MediaRemote (эксперимент)", isOn: $preferences.experimentalYandexEnabled)
                    Text("Только локальная проверка. Команды идут системному плееру; проверка источника не атомарна.")
                        .font(.system(size: 10)).foregroundStyle(Color.chelkaMuted).lineLimit(3)
                }
                if let message = preferences.loginMessage { Text(message).font(.system(size: 11)).foregroundStyle(Color.chelkaMuted).lineLimit(3) }
                Spacer()
            }.frame(maxWidth: .infinity)
        }.onAppear { preferences.refreshLoginStatus() }
    }
    private func preferenceToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 10)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.white)
        }
    }
}

struct MagneticView: View {
    let status: FileDropStatus
    private var title: String {
        switch status {
        case .ready: return "Отпустите файлы"
        case .copying: return "Копирование на полку…"
        }
    }
    private var detail: String {
        switch status {
        case .ready(let count): return "\(fileCount(count)) · Оригиналы останутся на месте"
        case .copying(let count): return fileCount(count)
        }
    }
    var body: some View {
        VStack(spacing: 9) {
            if case .copying = status { ProgressView().controlSize(.small) }
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineLimit(2).multilineTextAlignment(.center)
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 5])) }
            .accessibilityElement(children: .combine).accessibilityIdentifier("ForelockFileDrop")
    }
}

/// The same Shelf items, thumbnails, native drag source and Quick Look route.
/// Only the IDs of the latest import are selected for this compact presentation.
struct RecentFilesView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    private var tileWidth: CGFloat { max(64, min(110, (model.surfaceSize.width - 70) / 4)) }
    private var resultError: String? { model.selectionError ?? model.recentDrop?.error }
    private var rowHeight: CGFloat { model.hasShelfSelection && resultError != nil ? 76 : 88 }
    private var summary: String {
        if let message = model.selectionMessage { return message }
        guard let result = model.recentDrop else { return "" }
        if result.itemIDs.isEmpty { return "Не удалось добавить файлы" }
        if model.recentItems.count != result.itemIDs.count { return "На мини-полке: \(fileCount(model.recentItems.count))" }
        return result.itemIDs.count == result.attempted ? "Добавлено: \(fileCount(result.itemIDs.count))" : "Добавлено \(result.itemIDs.count) из \(result.attempted)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.hasShelfSelection { ShelfSelectionActions(model: model, compact: true) }
            else { Text(summary).font(.system(size: 12, weight: .medium)) }
            if !model.miniShelfItems.isEmpty {
                HStack(spacing: 10) {
                    ForEach(model.miniShelfItems) { item in
                        SelectableShelfTile(model: model, shelf: shelf, item: item)
                            .frame(width: tileWidth, height: rowHeight)
                    }
                    if model.miniShelfOverflow > 0 {
                        Button { model.open(.shelf, reason: "recent-overflow") } label: {
                            Text("+\(model.miniShelfOverflow)").font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Color.chelkaMuted).frame(width: tileWidth, height: rowHeight)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Ещё \(model.miniShelfOverflow). Все файлы")
                    }
                    if model.miniShelfItems.count < 4 && model.miniShelfOverflow == 0 { Spacer(minLength: 0).frame(maxWidth: .infinity) }
                }
            }
            if let error = resultError {
                Text(error).font(.system(size: 10)).foregroundStyle(Color.chelkaMuted)
                    .lineLimit(model.miniShelfItems.isEmpty ? 5 : 2).fixedSize(horizontal: false, vertical: true)
                    .help(error).accessibilityLabel(error)
            } else {
                Text(model.recentItems.isEmpty ? "Добавленные копии удалены с полки." : "Клик — просмотр. ⌘ клик — выбор. Потяните, чтобы забрать.")
                    .font(.system(size: 10)).foregroundStyle(Color.chelkaMuted)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ShelfFocusRegion().accessibilityHidden(true))
            .simultaneousGesture(TapGesture().onEnded { model.requestShelfFocus?() })
            .accessibilityIdentifier("ForelockRecentFiles")
    }
}
struct SelectableShelfTile: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    let item: ShelfItem
    var body: some View {
        NativeFileTile(item: item, image: shelf.image(item), url: shelf.url(for: item),
                       open: { model.shelfClick(item.id, modifiers: []) }, dragChanged: { model.draggingOut = $0 },
                       selected: model.selection.ids.contains(item.id),
                       click: { model.shelfClick(item.id, modifiers: $0) },
                       dragEntries: { model.shelfDragItems(from: item.id).map { ShelfDragEntry(url: shelf.url(for: $0), image: shelf.image($0)) } },
                       interactionChanged: { model.shelfPointerInteracting = $0 })
    }
}
struct ShelfSelectionActions: View {
    @ObservedObject var model: NotchModel
    var compact = false
    private var count: String { "Выбрано: \(model.selection.ids.count)" }
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    Text(count).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 4)
                    Button("Удалить копии", action: model.deleteSelectedCopies)
                    Button("Снять") { clear() }.accessibilityLabel("Снять выделение")
                }.font(.system(size: 11)).buttonStyle(.plain).frame(height: 28)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(count).font(.system(size: 16, weight: .medium))
                    SurfaceButton("Удалить копии", symbol: "trash", action: model.deleteSelectedCopies)
                    SurfaceButton("Снять выделение", symbol: "xmark") { clear() }
                }
            }
        }.disabled(model.isInteracting || model.draggingOut || model.shelf.loading)
            .help("Удаляются только выбранные копии Forelock. Оригиналы не затрагиваются.")
            .accessibilityIdentifier("ForelockShelfSelection")
    }
    private func clear() { model.clearShelfSelection(); model.requestShelfFocus?() }
}
struct SmallIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(Color.chelkaMuted)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}
struct SurfaceButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    let action: () -> Void
    init(_ title: String, symbol: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.prominent = prominent; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { if let symbol { Image(systemName: symbol).font(.system(size: 12)) }; Text(title).font(.system(size: 12, weight: .medium)) }
                .foregroundStyle(prominent ? Color.black : Color.chelkaText)
                .padding(.horizontal, 12).frame(minHeight: 34)
                .background(prominent ? Color.white : Color.white.opacity(0.085), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
struct SurfaceDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).frame(maxHeight: .infinity) }
}
func fileCount(_ count: Int) -> String {
    let mod100 = count % 100
    let word = (11...14).contains(mod100) ? "файлов" : count % 10 == 1 ? "файл" : (2...4).contains(count % 10) ? "файла" : "файлов"
    return "\(count) \(word)"
}
