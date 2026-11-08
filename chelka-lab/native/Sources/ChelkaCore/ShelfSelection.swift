import Foundation

/// Transient IDs in a presentation order; never persisted with Shelf files.
public struct ShelfSelection: Equatable, Sendable {
    public private(set) var ids: Set<UUID> = []
    public private(set) var anchor: UUID?
    public init() {}
    public mutating func reconcile(_ ordered: [UUID]) {
        let valid = Set(ordered); ids.formIntersection(valid)
        if let anchor, !valid.contains(anchor) { self.anchor = nil }
    }
    public mutating func clear(keepingAnchor: Bool = false) { ids.removeAll(); if !keepingAnchor { anchor = nil } }
    public mutating func plainClick(_ id: UUID) { ids.removeAll(); anchor = id }
    public mutating func toggle(_ id: UUID, ordered: [UUID]) {
        reconcile(ordered); guard ordered.contains(id) else { return }
        if !ids.insert(id).inserted { ids.remove(id) }; anchor = id
    }
    public mutating func range(to id: UUID, ordered: [UUID], additive: Bool) {
        reconcile(ordered); guard let end = ordered.firstIndex(of: id) else { return }
        let start = anchor.flatMap { ordered.firstIndex(of: $0) } ?? end
        let range = Set(ordered[min(start,end)...max(start,end)])
        if additive { ids.formUnion(range) } else { ids = range }
        if anchor == nil { anchor = id }
    }
    public mutating func selectAll(_ ordered: [UUID]) { reconcile(ordered); ids = Set(ordered); if anchor == nil { anchor = ordered.first } }
    public func dragIDs(from id: UUID, ordered: [UUID]) -> [UUID] {
        guard ordered.contains(id) else { return [] }
        return ids.contains(id) ? ordered.filter { ids.contains($0) } : [id]
    }
}
