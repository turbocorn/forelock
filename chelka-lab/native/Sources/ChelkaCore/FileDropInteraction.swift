import CoreGraphics

/// A mouse gesture is only permission to offer a temporary AppKit destination.
/// It is never evidence of a file; only NSDraggingInfo can provide that evidence.
public struct FileDragProbe: Sendable {
    private var sawDrag = false
    public private(set) var isRejected = false
    public private(set) var isArmed = false
    public init() {}
    public mutating func observeDraggedMouse() { sawDrag = true }
    public mutating func rejectUntilMouseUp() { isRejected = true; isArmed = false }
    public mutating func reset() { self = FileDragProbe() }
    public mutating func sample(leftPressed: Bool, nearNotch: Bool, blocked: Bool) {
        guard leftPressed else { reset(); return }
        isArmed = sawDrag && !isRejected && nearNotch && !blocked
    }
}

public enum FileDropLayout {
    /// Exists only during an observed, pressed drag near the notch. The visible
    /// surface still has its original screen-top anchor and independent spring.
    public static func captureSize(_ geometry: NotchGeometry) -> CGSize {
        CGSize(width: min(640, geometry.screenFrame.width - 64), height: geometry.headerHeight + 222)
    }
    public static func approachRegion(_ geometry: NotchGeometry) -> CGRect {
        geometry.frame(for: captureSize(geometry)).insetBy(dx: -64, dy: -64).intersection(geometry.screenFrame)
    }
    public static func surfaceSize(_ geometry: NotchGeometry?) -> CGSize {
        CGSize(width: min(520, geometry?.expandedWidth ?? 520), height: (geometry?.headerHeight ?? 38) + 170)
    }
    /// Identical rect for the dashed outline and the native drop hit test.
    public static func dropRect(in size: CGSize, headerHeight: CGFloat) -> CGRect {
        CGRect(x: 20, y: headerHeight + 12, width: max(0, size.width - 40), height: max(0, size.height - headerHeight - 28))
    }
}
