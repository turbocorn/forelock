import CoreGraphics

public enum NotchInteractionMode: String, Sendable { case idle, hover, expanded }
public enum NotchPointerAction: Equatable, Sendable { case openHover, closeHover }

/// Activation is limited to the idle footprint. Retention includes the camera
/// on a physical notch even though it contains no controls.
public struct NotchPointerRegions: Sendable {
    public let activation: CGRect
    public let inActivation: Bool
    public let inSurface: Bool
    public let inControls: Bool
    public var retainsHover: Bool { inActivation || inSurface }

    public init(geometry: NotchGeometry, frame: CGRect, pointer: CGPoint, paintedBounds: CGRect? = nil) {
        activation = geometry.frame(for: geometry.idleSize)
        // macOS can report mouseLocation.y == screen.frame.maxY at the upper
        // screen edge. CGRect.contains excludes maxY; this is still the camera,
        // without extending the activation rectangle by a compensation inset.
        let insideIdle = pointer.x >= activation.minX && pointer.x < activation.maxX &&
            pointer.y >= activation.minY && pointer.y <= activation.maxY
        let local = CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
        let painted=paintedBounds ?? CGRect(origin:.zero,size:frame.size)
        let relative=CGPoint(x:local.x-painted.minX,y:local.y-painted.minY)
        let insideFrame = geometry.hasNotch ? frame.contains(pointer) :
            pointer.x >= frame.minX && pointer.x < frame.maxX && pointer.y > frame.minY && pointer.y <= frame.maxY
        inSurface = insideFrame && painted.contains(local) && geometry.outline(for:painted.size).contains(relative)
        inControls = inSurface && !geometry.cameraRegion(for:frame.size).contains(local)
        let idlePoint = CGPoint(x: pointer.x - activation.minX, y: activation.maxY - pointer.y)
        inActivation = insideIdle && (geometry.hasNotch ||
            (inSurface && geometry.outline(for: geometry.idleSize).contains(idlePoint)))
    }

    public func acceptsMouse(in mode: NotchInteractionMode) -> Bool {
        // The measured camera rectangle also receives native NSDraggingInfo.
        // Outside that rectangle an Idle/closing window is always click-through.
        inActivation || (mode != .idle && inControls)
    }
}

/// The only owner of hover deadlines. Mouse-exit events never dismiss a panel.
public struct NotchPointerPolicy: Sendable {
    public private(set) var hoverSince: Double?
    public private(set) var outsideSince: Double?
    public private(set) var suppressedUntilExit = false
    public static let closeDelay = 0.6

    public init() {}
    public mutating func transitioned(to mode: NotchInteractionMode) {
        hoverSince = nil
        outsideSince = nil
        if mode == .idle { suppressedUntilExit = true }
    }
    public mutating func resetTimers() { hoverSince = nil; outsideSince = nil }

    public mutating func sample(mode: NotchInteractionMode, now: Double,
                                inActivation: Bool, retainsHover: Bool, pressed: Bool,
                                suspended: Bool, hoverEnabled: Bool, hoverDelay: Double) -> NotchPointerAction? {
        if !inActivation { suppressedUntilExit = false }
        guard !suspended else { resetTimers(); return nil }
        switch mode {
        case .idle:
            outsideSince = nil
            guard hoverEnabled, !suppressedUntilExit, inActivation, !pressed else { hoverSince = nil; return nil }
            if hoverSince == nil { hoverSince = now }
            if now - (hoverSince ?? now) >= hoverDelay { hoverSince = nil; return .openHover }
        case .hover:
            hoverSince = nil
            guard !retainsHover, !pressed else { outsideSince = nil; return nil }
            if outsideSince == nil { outsideSince = now }
            if now - (outsideSince ?? now) >= Self.closeDelay { outsideSince = nil; return .closeHover }
        case .expanded:
            // Pinned until a close action, Escape or outside mouse-down.
            resetTimers()
        }
        return nil
    }
}
