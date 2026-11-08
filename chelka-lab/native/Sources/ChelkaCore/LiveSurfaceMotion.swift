import Foundation
import CoreGraphics

/// Presentation only: a fixed camera-centred canvas with independently painted
/// shoulders. Transparent canvas never becomes a hit target.
public struct LiveSurfaceFootprint: Equatable, Sendable {
    public let size:CGSize
    /// width = left inset, height = right inset (not a view size).
    public let insets:CGSize
}

/// Uses the existing frame clock; no timers, queue or event policy here.
public struct SurfaceContentFade: Sendable {
    public private(set) var key:String?
    public private(set) var opacity:Double=0
    private var requested:String?
    public init() {}
    public mutating func request(_ key:String?) {requested=key}
    public mutating func snap(to key:String?) {requested=key;self.key=key;opacity=key == nil ? 0 : 1}
    public mutating func step(dt:Double,ready:Bool,reduced:Bool)->Bool {
        let previous=key,h=min(0.05,max(0,dt))
        if reduced {snap(to:requested);return previous != key}
        if key != requested {
            opacity=max(0,opacity-h/0.07)
            if opacity==0 {key=requested}
        }
        if key == requested,key != nil,ready {opacity=min(1,opacity+h/0.14)}
        if key == nil {opacity=0}
        return previous != key
    }
}
