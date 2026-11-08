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

struct NativeFileTile: NSViewRepresentable {
    let item: ShelfItem
    let image: NSImage
    let url: URL
    let open: () -> Void
    let dragChanged: (Bool) -> Void

    func makeNSView(context: Context) -> DraggableFileView {
        let view = DraggableFileView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: DraggableFileView, context: Context) {
        view.fileURL = url
        view.thumbnail = image
        view.open = open
        view.dragChanged = dragChanged
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Просмотреть \(item.name)")
        view.setAccessibilityHelp("Нажмите для просмотра. Перетащите, чтобы скопировать в Finder.")
        view.host.rootView = FileTileVisual(name: item.name, image: image)
    }
}

final class DraggableFileView: NSView, NSDraggingSource {
    var fileURL: URL?
    var thumbnail = NSImage()
    var open: (() -> Void)?
    var dragChanged: ((Bool) -> Void)?
    let host = NSHostingView(rootView: FileTileVisual(name: "", image: NSImage()))
    private var start = NSPoint.zero
    private var didDrag = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor), host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); didDrag = false }
    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let fileURL else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) > 3 else { return }
        didDrag = true
        dragChanged?(true)
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(NSRect(x: start.x - 24, y: start.y - 24, width: 48, height: 48), contents: thumbnail)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) { if !didDrag { open?() } }
    override func accessibilityPerformPress() -> Bool { open?(); return true }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragChanged?(false); didDrag = false }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

struct FileTileVisual: View {
    let name: String
    let image: NSImage
    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 52, height: 52)
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.chelkaText)
        }
        .padding(.horizontal, 7).frame(maxWidth: .infinity, maxHeight: .infinity)

    }
}
