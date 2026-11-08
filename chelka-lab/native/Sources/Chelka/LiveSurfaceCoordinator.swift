import Foundation
import Combine
import ChelkaCore
import ForelockMusic

@MainActor final class LiveSurfaceCoordinator: ObservableObject {
    @Published private(set) var presentation = LiveSurfacePresentation()
    private(set) var engine = LiveSurfaceEngine()
    private var context = LiveSurfaceContext()
    private var deadline: Date?
    private var left: LiveSlotChoice = .auto, right: LiveSlotChoice = .auto
    private var subscriptions = Set<AnyCancellable>()
    private var operationBefore: Set<UUID>?
    private var inventory = 0
    private let shelf: ShelfModel
    var performAction: ((LiveSurfaceAction)->Void)?

    init(music:MusicCoordinator,shelf:ShelfModel,preferences:Preferences) {
        self.shelf=shelf
        music.$registry.sink { [weak self] registry in self?.receiveMusic(registry.selected) }.store(in:&subscriptions)
        preferences.$liveLeft.combineLatest(preferences.$liveRight,preferences.$allowLiveFullscreen).sink { [weak self] left,right,allow in
            guard let self else{return};self.left=left;self.right=right;self.context.allowFullscreen=allow;self.refresh()
        }.store(in:&subscriptions)
        shelf.$items.sink { [weak self] items in self?.updateInventory(items.count) }.store(in:&subscriptions)
        shelf.$loading.dropFirst().sink { [weak self] loading in
            guard let self else{return}
            if loading {self.operationBefore=Set(shelf.items.map(\.id))}
            else if let before=self.operationBefore {
                self.operationBefore=nil
                let after=Set(shelf.items.map(\.id)),added=after.subtracting(before).count,removed=before.subtracting(after).count
                if added+removed>0 {
                    let now=Date()
                    self.ingest(LiveSurfaceEvent(source:.files,key:"completed",priority:.information,strategy:.stretch,category:.files,
                        createdAt:now,expiresAt:now.addingTimeInterval(8),title:added>0 ? "Файлы добавлены" : "Копии удалены",
                        detail:String(added+removed),symbol:"tray",handledByWorkspace:true))
                }
            }
        }.store(in:&subscriptions)
        shelf.$error.removeDuplicates().sink { [weak self] error in
            guard let self else{return}
            self.engine.remove(source:.files,key:"error")
            if let error,!error.isEmpty {
                let now=Date()
                self.ingest(LiveSurfaceEvent(source:.files,key:"error",priority:.reaction,strategy:.attention,category:.activities,
                    createdAt:now,expiresAt:now.addingTimeInterval(45),title:"Ошибка полки",detail:String(error.prefix(512)),symbol:"exclamationmark.circle",action:.openShelf,handledByWorkspace:true))
            } else { self.refresh() }
        }.store(in:&subscriptions)
    }
    func receiveMusic(_ snapshot:MusicSnapshot?,now:Date=Date()) {
        engine.remove(source:.music)
        if let s=snapshot,s.state == .playing {
            let age=s.service == .yandexDesktop ? NowPlayingLimits.confirmationAge : 7
            if now.timeIntervalSince(s.updatedAt)>=0,now.timeIntervalSince(s.updatedAt)<age {
                engine.ingest(LiveSurfaceEvent(source:.music,key:"playing",priority:.background,strategy:.ambient,category:.music,
                    createdAt:s.updatedAt,expiresAt:s.updatedAt.addingTimeInterval(age),title:"Музыка",detail:String((s.title+" · "+s.artist).prefix(512)),symbol:"music.note",replace:true),now:now,context:context)
            }
        }
        refresh(now)
    }
    private func updateInventory(_ count:Int) {
        inventory=count
        engine.remove(source:.files,key:"inventory")
        refresh()
    }
    private func renewInventory(_ now:Date) {
        // Inventory is real but is not background activity in Auto. It appears
        // only when the user explicitly chooses Files for a slot.
        engine.remove(source:.files,key:"inventory")
        if inventory>0 && (left == .files || right == .files) {
            engine.ingest(LiveSurfaceEvent(source:.files,key:"inventory",priority:.background,strategy:.ambient,category:.files,
                createdAt:now,expiresAt:now.addingTimeInterval(120),title:String(inventory),detail:"Файлов на полке: \(inventory)",symbol:"tray",allowsAuto:false,replace:true),now:now,context:context)
        }
    }
    func setContext(workspace:Bool,fullscreen:Bool,peekEngaged:Bool,now:Date=Date()) {
        var next=context;next.workspace=workspace;next.fullscreen=fullscreen;next.peekEngaged=peekEngaged
        guard next != context else{return};context=next;refresh(now)
    }
    func tick(now:Date=Date()) { if let deadline,now>=deadline {refresh(now)} }
    func ingest(_ event:LiveSurfaceEvent,now:Date=Date()) {engine.ingest(event,now:now,context:context);refresh(now)}
    func dismissCurrent() {
        if let id=engine.currentID,let event=engine.events[id] {engine.remove(source:event.source,key:event.key)}
        refresh()
    }
    func act(on id:String) {
        guard presentation.event?.id == id,let action=presentation.event?.action else{return}
        dismissCurrent();performAction?(action)
    }
    private func refresh(_ now:Date=Date()) {
        renewInventory(now)
        let next=engine.advance(now:now,context:context,left:left,right:right)
        if next != presentation {presentation=next}
        deadline=engine.nextDeadline(context:context)
    }
#if DEBUG
    enum Diagnostic { case stretch, peek, attention, priorities, duplicates, clear }
    func diagnose(_ kind:Diagnostic) {
        let now=Date()
        func event(_ key:String,_ priority:LiveSurfacePriority,_ strategy:LiveSurfaceStrategy)->LiveSurfaceEvent {
            LiveSurfaceEvent(source:.diagnostic,key:key,priority:priority,strategy:strategy,category:.activities,
                createdAt:now,expiresAt:now.addingTimeInterval(12),title:strategy == .stretch ? "Тест Stretch" : "Тест Peek",
                detail:strategy == .stretch ? "Диагностика" : "Диагностическое событие. Файлы не изменяются.",symbol:priority == .reaction ? "exclamationmark.circle" : "checkmark",action:strategy == .peek ? .openShelf : nil)
        }
        switch kind {
        case .stretch:ingest(event("stretch",.information,.stretch))
        case .peek:ingest(event("peek",.reaction,.peek))
        case .attention:ingest(event("attention",.reaction,.attention))
        case .priorities:ingest(event("information",.information,.stretch));ingest(event("reaction",.reaction,.peek))
        case .duplicates:for _ in 0..<3 {ingest(event("duplicates",.information,.stretch))}
        case .clear:engine.remove(source:.diagnostic);refresh()
        }
    }
#endif
}
