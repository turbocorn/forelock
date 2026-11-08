import Foundation
import CoreGraphics

public enum LiveSurfaceMode: String, Equatable, Sendable { case silent, ambient, stretch, peek, workspace }
public enum LiveSurfaceSource: String, Sendable { case music, files, power, audio, devices, diagnostic }
public enum LiveSurfacePriority: Int, Comparable, Sendable {
    case reaction = 1, information = 2, background = 3
    public static func <(a:Self,b:Self)->Bool { a.rawValue < b.rawValue }
}
public enum LiveSurfaceStrategy: Equatable, Sendable { case ambient, attention, stretch, peek }
public enum LiveSurfaceCategory: Equatable, Sendable { case music, files, activities, devices, battery }
public enum LiveSurfaceAction: Equatable, Sendable { case openShelf }
public enum LiveSlotChoice: String, CaseIterable, Sendable { case auto, music, files, activities, battery, devices, nothing }
public struct LiveSurfaceContext: Equatable, Sendable {
    public var workspace = false, fullscreen = false, allowFullscreen = false, peekEngaged = false
    public init(workspace:Bool=false,fullscreen:Bool=false,allowFullscreen:Bool=false,peekEngaged:Bool=false) {
        self.workspace=workspace;self.fullscreen=fullscreen;self.allowFullscreen=allowFullscreen;self.peekEngaged=peekEngaged
    }
    var blocksAutomatic: Bool { workspace || (fullscreen && !allowFullscreen) }
}
public struct LiveSurfaceEvent: Equatable, Sendable {
    public let source: LiveSurfaceSource
    public let key: String
    public var priority: LiveSurfacePriority
    public var strategy: LiveSurfaceStrategy
    public var category: LiveSurfaceCategory
    public var createdAt: Date
    public var expiresAt: Date
    public var title: String
    public var detail: String
    public var symbol: String
    public var count: Int
    public var action: LiveSurfaceAction?
    public var allowsAuto: Bool
    public var replace: Bool
    public var handledByWorkspace: Bool
    public var id: String { source.rawValue + ":" + key }
    public init(source:LiveSurfaceSource,key:String,priority:LiveSurfacePriority,strategy:LiveSurfaceStrategy,category:LiveSurfaceCategory,
                createdAt:Date,expiresAt:Date,title:String,detail:String="",symbol:String,count:Int=1,action:LiveSurfaceAction?=nil,
                allowsAuto:Bool=true,replace:Bool=false,handledByWorkspace:Bool=false) {
        self.source=source;self.key=key;self.priority=priority;self.strategy=strategy;self.category=category
        self.createdAt=createdAt;self.expiresAt=expiresAt;self.title=title;self.detail=detail;self.symbol=symbol
        self.count=count;self.action=action;self.allowsAuto=allowsAuto;self.replace=replace;self.handledByWorkspace=handledByWorkspace
    }
    var transient: Bool { strategy == .stretch || strategy == .peek }
    var item: LiveSurfaceItem { LiveSurfaceItem(id:id,category:category,title:title,detail:detail,symbol:symbol,count:count,action:action,attention:priority == .reaction) }
}
/// UI payload deliberately excludes clocks and playback progress. Renewing a
/// trusted heartbeat does not redraw an otherwise unchanged static indicator.
public struct LiveSurfaceItem: Equatable, Sendable {
    public let id:String
    public let category:LiveSurfaceCategory
    public let title:String
    public let detail:String
    public let symbol:String
    public let count:Int
    public let action:LiveSurfaceAction?
    public let attention:Bool
}
public struct LiveSurfacePresentation: Equatable, Sendable {
    public var mode:LiveSurfaceMode = .silent
    public var event:LiveSurfaceItem?
    public var left:LiveSurfaceItem?
    public var right:LiveSurfaceItem?
    public init() {}
}

/// Bounded, deterministic arbitration. P0 is context, never another queued event.
public struct LiveSurfaceEngine: Sendable {
    public static let capacity = 8, transientCapacity = 3
    public private(set) var events:[String:LiveSurfaceEvent] = [:]
    public private(set) var currentID:String?
    public private(set) var handledInWorkspace = 0
    private var endsAt:Date?
    public init() {}
    public mutating func remove(source:LiveSurfaceSource,key:String) {
        let id=source.rawValue+":"+key;events[id]=nil
        if currentID == id { currentID=nil;endsAt=nil }
    }
    public mutating func remove(source:LiveSurfaceSource) {
        for event in Array(events.values) where event.source == source { remove(source:source,key:event.key) }
    }
    public mutating func ingest(_ incoming:LiveSurfaceEvent,now:Date,context:LiveSurfaceContext) {
        prune(now)
        var e=incoming
        guard !e.key.isEmpty,e.key.count<=128,e.title.count<=128,e.detail.count<=512,e.symbol.count<=64,
              e.createdAt <= now.addingTimeInterval(1),e.expiresAt>now,e.expiresAt>e.createdAt else { return }
        e.expiresAt=min(e.expiresAt,e.createdAt.addingTimeInterval(120));e.count=min(999,max(1,e.count))
        guard e.expiresAt>now else { return }
        if e.handledByWorkspace {
            handledInWorkspace=min(999999,handledInWorkspace+1)
            if e.priority != .reaction { return }
            e.strategy = .attention
        }
        if context.blocksAutomatic && e.transient {
            guard e.priority == .reaction else { return };e.strategy = .attention
        }
        if let old=events[e.id], !e.replace {
            e.count=min(999,old.count+e.count);e.createdAt=old.createdAt
            e.expiresAt=min(max(old.expiresAt,e.expiresAt),old.createdAt.addingTimeInterval(120))
            if old.priority<e.priority { e.priority=old.priority }
        }
        events[e.id]=e
        if currentID == e.id && !e.transient { currentID=nil;endsAt=nil }
        trim()
    }
    public mutating func advance(now:Date,context:LiveSurfaceContext,left:LiveSlotChoice = .auto,right:LiveSlotChoice = .auto)->LiveSurfacePresentation {
        prune(now)
        if context.blocksAutomatic {
            for e in Array(events.values) where e.transient {
                if e.priority == .reaction { var retained=e;retained.strategy = .attention;events[e.id]=retained }
                else { events[e.id]=nil }
            }
            currentID=nil;endsAt=nil
        } else {
            if let id=currentID,let end=endsAt,end<=now,!(events[id]?.strategy == .peek && context.peekEngaged) { finishCurrent() }
            let candidate=events.values.filter{$0.transient && $0.id != currentID}.sorted(by:precedes).first
            if let candidate, currentID == nil || candidate.priority < (events[currentID!]?.priority ?? .background) {
                finishCurrent();currentID=candidate.id
                endsAt=min(candidate.expiresAt,now.addingTimeInterval(candidate.strategy == .stretch ? 2.5 : 6))
            }
        }
        var result=LiveSurfacePresentation()
        if context.workspace { result.mode = .workspace;return result }
        if let id=currentID,let event=events[id] {
            result.mode=event.strategy == .peek ? .peek : .stretch;result.event=event.item;return result
        }
        let candidates=events.values.filter{!$0.transient}.sorted(by:precedes)
        var slots:[LiveSurfaceItem?]=[nil,nil],used=Set<String>()
        func unused(_ e:LiveSurfaceEvent)->Bool {
            !used.contains(e.id) && !slots.compactMap{$0}.contains { item in
                item.category == e.category && [.music,.battery,.devices].contains(e.category)
            }
        }
        let choices=[left,right]
        // Explicit slots reserve their item before Auto fills unused slots.
        for i in 0..<2 where choices[i] != .auto && choices[i] != .nothing {
            if let e=candidates.first(where:{matches($0.category,choices[i]) && unused($0)}) {slots[i]=e.item;used.insert(e.id)}
        }
        for i in 0..<2 where choices[i] == .auto {
            if let e=candidates.first(where:{$0.allowsAuto && unused($0)}) {slots[i]=e.item;used.insert(e.id)}
        }
        result.left=slots[0];result.right=slots[1]
        result.mode=slots.contains(where:{$0 != nil}) ? .ambient : .silent
        return result
    }
    public func nextDeadline(context:LiveSurfaceContext)->Date? {
        var dates=events.values.map(\.expiresAt)
        if let endsAt,!(context.peekEngaged && currentID.flatMap{events[$0]?.strategy} == .peek) {dates.append(endsAt)}
        return dates.min()
    }
    private mutating func finishCurrent() {
        if let id=currentID,let e=events[id] {
            if e.priority == .reaction { var retained=e;retained.strategy = .attention;events[id]=retained }
            else {events[id]=nil}
        }
        currentID=nil;endsAt=nil
    }
    private mutating func prune(_ now:Date) {
        for e in Array(events.values) where e.expiresAt<=now {events[e.id]=nil}
        if let currentID,events[currentID]==nil {self.currentID=nil;endsAt=nil}
    }
    private mutating func trim() {
        let transients=events.values.filter{$0.transient && $0.id != currentID}.sorted(by:precedes)
        for e in transients.dropFirst(Self.transientCapacity) {events[e.id]=nil}
        let ordered=events.values.sorted(by:precedes)
        for e in ordered.dropFirst(Self.capacity) {events[e.id]=nil;if currentID==e.id{currentID=nil;endsAt=nil}}
    }
    private func precedes(_ a:LiveSurfaceEvent,_ b:LiveSurfaceEvent)->Bool {
        if a.priority != b.priority{return a.priority<b.priority}
        if a.priority == .background,a.category != b.category {
            if a.category == .music {return true}
            if b.category == .music {return false}
        }
        if a.createdAt != b.createdAt{return a.createdAt>b.createdAt}
        return a.id<b.id
    }
    private func matches(_ category:LiveSurfaceCategory,_ choice:LiveSlotChoice)->Bool {
        switch(category,choice) {case(.music,.music),(.files,.files),(.activities,.activities),(.devices,.devices),(.battery,.battery):return true;default:return false}
    }
}

public enum LiveSurfaceLayout {
    public static func size(for mode:LiveSurfaceMode,geometry:NotchGeometry?,shoulderWidth:CGFloat?=nil)->CGSize {
        let idle=geometry?.idleSize ?? CGSize(width:220,height:38)
        let camera=(geometry?.hasNotch ?? true) ? (geometry?.neckWidth ?? 220)+24 : 0
        switch mode {
        case .silent,.workspace:return idle
        case .ambient:return CGSize(width:min(geometry?.expandedWidth ?? 900,max(idle.width,camera+2*(shoulderWidth ?? 52))),height:idle.height)
        case .stretch:return CGSize(width:min(geometry?.expandedWidth ?? 900,max(160,camera+2*(shoulderWidth ?? 112))),height:idle.height)
        case .peek:return CGSize(width:geometry?.hoverWidth ?? 420,height:(geometry?.headerHeight ?? 38)+126)
        }
    }
}
