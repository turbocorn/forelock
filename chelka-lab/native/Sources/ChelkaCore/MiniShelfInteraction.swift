import Foundation

/// Separate from the accepted hardware-hover policy. No fixed lifetime: only
/// time continuously outside the result counts, and interaction resets it.
public struct MiniShelfPointerPolicy: Sendable {
    public static let closeDelay: Double = 0.8
    private var presentation: UUID?
    private var outsideSince: Double?
    public init() {}
    public mutating func shouldDismiss(presentation id: UUID?, now: Double, inside: Bool, interacting: Bool) -> Bool {
        guard let id else { presentation = nil; outsideSince = nil; return false }
        if presentation != id { presentation = id; outsideSince = nil }
        guard !inside, !interacting else { outsideSince = nil; return false }
        if outsideSince == nil { outsideSince = now }
        return now - (outsideSince ?? now) >= Self.closeDelay
    }
}
