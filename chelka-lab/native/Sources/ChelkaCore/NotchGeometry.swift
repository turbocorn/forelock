import CoreGraphics
import Foundation

public struct NotchHeaderLayout: Equatable, Sendable {
    public let left: CGRect
    public let camera: CGRect
    public let right: CGRect
}

public struct NotchGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    public let anchor: CGPoint
    public let neckWidth: CGFloat
    public let neckHeight: CGFloat
    public let hasNotch: Bool
    public let menuBarHeight: CGFloat
    public var headerHeight: CGFloat { max(32, neckHeight) }

    public init(screenFrame: CGRect, visibleFrame: CGRect, safeTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?) {
        self.screenFrame = screenFrame
        self.menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        if safeTop > 0, let leftArea, let rightArea, rightArea.minX > leftArea.maxX {
            hasNotch = true
            neckWidth = rightArea.minX - leftArea.maxX
            neckHeight = safeTop
            anchor = CGPoint(x: (leftArea.maxX + rightArea.minX) / 2, y: screenFrame.maxY)
        } else {
            hasNotch = false
            neckWidth = 112
            neckHeight = 0
            anchor = CGPoint(x: screenFrame.midX, y: visibleFrame.maxY)
        }
    }

    public var idleSize: CGSize { CGSize(width: hasNotch ? neckWidth : 132, height: hasNotch ? neckHeight : 25) }
    public var hoverWidth: CGFloat { min(420, screenFrame.width - 48) }
    public var expandedWidth: CGFloat { min(900, screenFrame.width - 64) }

    /// A single full-width surface from the screen's top edge. Only the two
    /// lower external corners are rounded; camera/menu insets never move it down.
    public func outline(for size: CGSize) -> CGPath {
        let radius = min(28, size.height / 2)
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: size.width, y: 0))
        p.addLine(to: CGPoint(x: size.width, y: size.height - radius))
        p.addQuadCurve(to: CGPoint(x: size.width - radius, y: size.height), control: CGPoint(x: size.width, y: size.height))
        p.addLine(to: CGPoint(x: radius, y: size.height))
        p.addQuadCurve(to: CGPoint(x: 0, y: size.height - radius), control: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }

    public func cameraRegion(for size: CGSize) -> CGRect {
        guard hasNotch else { return .null }
        let width = min(neckWidth, size.width)
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: min(neckHeight, size.height))
    }

    public func headerLayout(for size: CGSize) -> NotchHeaderLayout {
        let cameraSlot = hasNotch ? min(size.width, neckWidth + 24) : 0
        let side = max(0, (size.width - cameraSlot) / 2)
        return NotchHeaderLayout(
            left: CGRect(x: 0, y: 0, width: side, height: headerHeight),
            camera: CGRect(x: side, y: 0, width: cameraSlot, height: headerHeight),
            right: CGRect(x: side + cameraSlot, y: 0, width: side, height: headerHeight))
    }

    public func containsInteractivePoint(_ point: CGPoint, in size: CGSize) -> Bool {
        outline(for: size).contains(point) && !cameraRegion(for: size).contains(point)
    }
    public func frame(for size: CGSize) -> CGRect {
        CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height)
    }
}

/// Semi-implicit spring with bounded substeps, so interruptions preserve velocity.
public struct SurfaceSpring: Sendable {
    public var value: CGSize
    public var velocity = CGSize.zero
    public init(_ value: CGSize) { self.value = value }
    public mutating func step(toward target: CGSize, dt: Double) -> Bool {
        let duration = min(max(dt, 0), 0.05)
        let count = max(1, Int(ceil(duration / (1.0 / 120))))
        let h = duration / Double(count)
        for _ in 0..<count {
            velocity.width += ((target.width - value.width) * 340 - velocity.width * 31) / 0.9 * h
            velocity.height += ((target.height - value.height) * 340 - velocity.height * 31) / 0.9 * h
            value.width += velocity.width * h
            value.height += velocity.height * h
        }
        let settled = abs(target.width - value.width) < 0.08 && abs(target.height - value.height) < 0.08 && abs(velocity.width) < 0.12 && abs(velocity.height) < 0.12
        if settled { value = target; velocity = .zero }
        return settled
    }
}
