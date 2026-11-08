import AppKit

/// One destination and one window, including the temporary approach canvas.
/// No global pasteboard reads. A rejected tab/text drag disarms the probe.
final class DropHostingView: NSView {
    var accept: (([URL], Int) -> Bool)?
    var acceptsDrag: (() -> Bool)?
    var dragEntered: ((Int, Int) -> Void)?
    var dragExited: ((Int) -> Void)?
    var dragEnded: ((Int) -> Void)?
    var dragRejected: (() -> Void)?
    var acceptsPoint: ((CGPoint) -> Bool)?
    var presentationSize: CGSize? { didSet { if oldValue != presentationSize { needsLayout = true } } }
    private var committedSequence: Int?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        let size = presentationSize ?? bounds.size
        subviews.first?.frame = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }
    private func urls(_ info: NSDraggingInfo) -> [URL] {
        guard acceptsDrag?() != false, info.draggingSourceOperationMask.contains(.copy),
              committedSequence != info.draggingSequenceNumber else { return [] }
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func pointIsAccepted(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let size = presentationSize ?? bounds.size
        return acceptsPoint?(CGPoint(x: point.x - (bounds.width - size.width) / 2, y: point.y)) == true
    }
    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let files = urls(sender)
        guard !files.isEmpty else { dragRejected?(); return [] }
        dragEntered?(sender.draggingSequenceNumber, files.count)
        sender.numberOfValidItemsForDrop = files.count
        return pointIsAccepted(sender) ? .copy : []
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { if let sender { dragExited?(sender.draggingSequenceNumber) } }
    override func draggingEnded(_ sender: NSDraggingInfo) { end(sender) }
    private func end(_ sender: NSDraggingInfo) {
        dragEnded?(sender.draggingSequenceNumber)
        if committedSequence == sender.draggingSequenceNumber { committedSequence = nil }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty && pointIsAccepted(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty, pointIsAccepted(sender), accept?(files, sender.draggingSequenceNumber) == true else { return false }
        committedSequence = sender.draggingSequenceNumber
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { if let sender { end(sender) } }
}
