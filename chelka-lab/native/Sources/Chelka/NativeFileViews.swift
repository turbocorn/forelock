import AppKit
import SwiftUI
import QuickLookUI
import ChelkaCore

struct EmbeddedQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem?.previewItemURL ?? nil) != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) { nsView.close() }
}

struct ShelfDragEntry {
    let url: URL
    let image: NSImage
}

struct NativeFileTile: NSViewRepresentable {
    let item: ShelfItem
    let image: NSImage
    let url: URL
    let open: () -> Void
    let dragChanged: (Bool) -> Void
    var selected = false
    var click: ((NSEvent.ModifierFlags) -> Void)? = nil
    var dragEntries: (() -> [ShelfDragEntry])? = nil
    var interactionChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> DraggableFileView {
        let view = DraggableFileView(); updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: DraggableFileView, context: Context) {
        view.fileURL = url; view.thumbnail = image; view.open = open
        view.dragChanged = dragChanged; view.click = click; view.dragEntries = dragEntries
        view.interactionChanged = interactionChanged
        view.selectionEnabled = click != nil
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Просмотреть \(item.name)")
        view.setAccessibilityValue(selected ? "Выбрано" : "")
        view.setAccessibilityHelp(click == nil ? "Нажмите для просмотра. Перетащите, чтобы скопировать в Finder." : "Клик — просмотр. Command + клик — выделение. Перетащите выбранную карточку, чтобы скопировать группу.")
        view.setAccessibilityCustomActions(click == nil ? [] : [NSAccessibilityCustomAction(name: selected ? "Снять выделение" : "Выделить", handler: { [weak view] in
            guard let view else { return false }; view.focusShelf(); view.click?(.command); return true
        })])
        view.host.rootView = FileTileVisual(name: item.name, image: image, selected: selected)
    }
}

final class DraggableFileView: NSView, NSDraggingSource {
    var fileURL: URL?
    var thumbnail = NSImage()
    var open: (() -> Void)?
    var click: ((NSEvent.ModifierFlags) -> Void)?
    var dragEntries: (() -> [ShelfDragEntry])?
    var dragChanged: ((Bool) -> Void)?
    var interactionChanged: ((Bool) -> Void)?
    var selectionEnabled = false
    let host = NSHostingView(rootView: FileTileVisual(name: "", image: NSImage()))
    private var start = NSPoint.zero
    private var clickModifiers: NSEvent.ModifierFlags = []
    private var didDrag = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        host.translatesAutoresizingMaskIntoConstraints = false; addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor), host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    func focusShelf() { window?.makeKey(); window?.makeFirstResponder(self) }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil); clickModifiers = event.modifierFlags; didDrag = false
        focusShelf(); interactionChanged?(true)
    }
    static func makeDraggingItems(_ entries: [ShelfDragEntry], at start: NSPoint) -> [NSDraggingItem] {
        entries.filter { $0.url.isFileURL }.enumerated().map { index, entry in
            let item = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
            let offset = CGFloat(min(index,4)) * 7
            item.setDraggingFrame(NSRect(x:start.x-24+offset,y:start.y-24-offset,width:48,height:48),contents:entry.image)
            return item
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x-start.x,current.y-start.y)>3 else { return }
        let entries = dragEntries?() ?? fileURL.map { [ShelfDragEntry(url:$0,image:thumbnail)] } ?? []
        let items = Self.makeDraggingItems(entries,at:start)
        guard !items.isEmpty else { return }
        dragDidBegin()
        let session = beginDraggingSession(with:items,event:event,source:self)
        session.draggingFormation = items.count>1 ? .pile : .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) {
        interactionChanged?(false)
        if !didDrag { if let click { click(clickModifiers) } else { open?() } }
    }
    override func accessibilityPerformPress() -> Bool {
        focusShelf(); if let click { click([]) } else { open?() }; return true
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .copy }
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {
        dragDidEnd()
    }
    func dragDidBegin() { didDrag = true; dragChanged?(true) }
    func dragDidEnd() {
        dragChanged?(false); interactionChanged?(false)
        // Keep didDrag until the next mouseDown. A late mouseUp after cancel must
        // not open Quick Look or toggle a selection.
    }
    func ignoreModifierKeys(for session:NSDraggingSession)->Bool { true }
}

struct ShelfFocusRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfFocusView { ShelfFocusView() }
    func updateNSView(_ view: ShelfFocusView, context: Context) {}
}
final class ShelfFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    // A focus marker must never sit on top of SwiftUI controls or consume clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct FileTileVisual: View {
    let name: String
    let image: NSImage
    var selected = false
    var body: some View {
        VStack(spacing:5) {
            Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(width:52,height:52)
            Text(name).font(.system(size:12,weight:.medium)).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.chelkaText)
        }.padding(.horizontal,7).frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(selected ? Color.white.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:8))
            .overlay { RoundedRectangle(cornerRadius:8).strokeBorder(selected ? Color.white.opacity(0.7) : Color.clear,lineWidth:1) }
            .overlay(alignment:.topLeading) {
                if selected { Image(systemName:"checkmark.circle.fill").font(.system(size:12)).foregroundStyle(Color.chelkaText).background(Color.black,in:Circle()).padding(4) }
            }
    }
}
