import XCTest
import AppKit
import Combine
import ChelkaCore
import ForelockMusic
@testable import Chelka

final class LiveSurfaceTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:1000)
    private func event(_ key:String="test",priority:LiveSurfacePriority = .information,strategy:LiveSurfaceStrategy = .stretch,
                       ttl:Double=15,handled:Bool=false)->LiveSurfaceEvent {
        LiveSurfaceEvent(source:.diagnostic,key:key,priority:priority,strategy:strategy,category:.activities,
                         createdAt:now,expiresAt:now.addingTimeInterval(ttl),title:key,symbol:"checkmark",handledByWorkspace:handled)
    }
    func testStretchReturnsToCurrentAmbientRatherThanSavedFrame() {
        var e=LiveSurfaceEngine();let context=LiveSurfaceContext()
        var music=event("music",priority:.background,strategy:.ambient);music.category = .music
        e.ingest(music,now:now,context:context)
        e.ingest(event(),now:now,context:context)
        XCTAssertEqual(e.advance(now:now,context:context).mode,.stretch)
        e.remove(source:.diagnostic,key:"music")
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(2.6),context:context).mode,.silent)
        music.detail="New source";e.ingest(music,now:now.addingTimeInterval(3),context:context)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(3),context:context).left?.detail,"New source")
    }
    func testReactionPreemptsInformationAndPeekEndsAsAttention() {
        var e=LiveSurfaceEngine();let c=LiveSurfaceContext()
        e.ingest(event("information"),now:now,context:c)
        XCTAssertEqual(e.advance(now:now,context:c).mode,.stretch)
        e.ingest(event("reaction",priority:.reaction,strategy:.peek),now:now,context:c)
        XCTAssertEqual(e.advance(now:now,context:c).event?.id,"diagnostic:reaction")
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(6.1),context:c).mode,.ambient)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(6.1),context:c).left?.attention,true)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(16),context:c).mode,.silent)
    }
    func testWorkspaceSuppressesBothIncomingAndQueuedEventsWithoutReplay() {
        var e=LiveSurfaceEngine();let busy=LiveSurfaceContext(workspace:true)
        e.ingest(event("first"),now:now,context:LiveSurfaceContext())
        _=e.advance(now:now,context:LiveSurfaceContext())
        e.ingest(event("second"),now:now,context:busy)
        e.ingest(event("error",priority:.reaction,strategy:.peek),now:now,context:busy)
        XCTAssertEqual(e.advance(now:now,context:busy).mode,.workspace)
        let result=e.advance(now:now.addingTimeInterval(1),context:LiveSurfaceContext())
        XCTAssertEqual(result.mode,.ambient);XCTAssertEqual(result.left?.id,"diagnostic:error")
        XCTAssertTrue(e.events.values.allSatisfy{$0.strategy == .attention})
    }
    func testFullscreenBlocksAutomaticExpansionByDefaultButCanBeEnabled() {
        var e=LiveSurfaceEngine();let c=LiveSurfaceContext(fullscreen:true)
        e.ingest(event(),now:now,context:c);XCTAssertEqual(e.advance(now:now,context:c).mode,.silent)
        let allowed=LiveSurfaceContext(fullscreen:true,allowFullscreen:true)
        e.ingest(event(),now:now,context:allowed);XCTAssertEqual(e.advance(now:now,context:allowed).mode,.stretch)
        XCTAssertEqual(e.advance(now:now,context:c).mode,.silent)
    }
    func testDedupDoesNotRestartDisplayAndQueueIsBounded() {
        var e=LiveSurfaceEngine();let c=LiveSurfaceContext()
        e.ingest(event(),now:now,context:c);_=e.advance(now:now,context:c)
        e.ingest(event(),now:now.addingTimeInterval(1),context:c)
        e.ingest(event(),now:now.addingTimeInterval(2),context:c)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(2),context:c).event?.count,3)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(2.6),context:c).mode,.silent)
        for i in 0..<100 {e.ingest(event("queued\(i)"),now:now,context:c)}
        XCTAssertLessThanOrEqual(e.events.count,LiveSurfaceEngine.transientCapacity)
        for i in 0..<100 {e.ingest(event("ambient\(i)",priority:.background,strategy:.ambient),now:now,context:c)}
        XCTAssertLessThanOrEqual(e.events.count,LiveSurfaceEngine.capacity)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(121),context:c).mode,.silent)
    }
    func testExpiredMalformedAndFutureEventsAreRejectedAndTTLIsCapped() {
        var e=LiveSurfaceEngine();let c=LiveSurfaceContext()
        e.ingest(event(ttl:0),now:now,context:c)
        var future=event("future");future.createdAt=now.addingTimeInterval(10)
        e.ingest(future,now:now,context:c)
        var oversized=event("oversize");oversized.detail=String(repeating:"x",count:513)
        e.ingest(oversized,now:now,context:c);XCTAssertTrue(e.events.isEmpty)
        e.ingest(event(ttl:9999),now:now,context:c)
        XCTAssertEqual(e.events.values.first?.expiresAt,now.addingTimeInterval(120))
    }
    func testSlotsDoNotDuplicateMusicOrInventActivityAndNothingIsSilent() {
        var e=LiveSurfaceEngine();let c=LiveSurfaceContext()
        var music=event("music",priority:.background,strategy:.ambient);music.category = .music
        e.ingest(music,now:now,context:c)
        let explicit=e.advance(now:now,context:c,left:.auto,right:.music)
        XCTAssertNil(explicit.left);XCTAssertNotNil(explicit.right)
        XCTAssertNil(e.advance(now:now,context:c,left:.music,right:.music).right)
        XCTAssertEqual(e.advance(now:now,context:c,left:.nothing,right:.nothing).mode,.silent)
        XCTAssertEqual(e.advance(now:now,context:c,left:.devices,right:.files).mode,.silent)
    }
    func testPeekRetentionIsBoundedByTTLAndDowngradeClearsCurrent() {
        var e=LiveSurfaceEngine();let c=LiveSurfaceContext()
        e.ingest(event(priority:.reaction,strategy:.peek),now:now,context:c)
        _=e.advance(now:now,context:c)
        let engaged=LiveSurfaceContext(peekEngaged:true)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(8),context:engaged).mode,.peek)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(16),context:engaged).mode,.silent)
        e.ingest(event(priority:.reaction,strategy:.peek),now:now,context:c);_=e.advance(now:now,context:c)
        e.ingest(event(priority:.reaction,strategy:.attention),now:now,context:c)
        XCTAssertEqual(e.advance(now:now,context:c).mode,.ambient);XCTAssertNil(e.currentID)
    }
    func testWorkspaceHandledCompletionNeverDuplicatesMiniShelf() {
        var e=LiveSurfaceEngine();let c=LiveSurfaceContext()
        e.ingest(event(handled:true),now:now,context:c)
        XCTAssertEqual(e.handledInWorkspace,1);XCTAssertTrue(e.events.isEmpty)
        e.ingest(event("error",priority:.reaction,strategy:.peek,handled:true),now:now,context:c)
        XCTAssertEqual(e.advance(now:now,context:c).mode,.ambient)
    }
    @MainActor private func model() -> NotchModel {
        let domain="dev.forelock.live-test.\(UUID())",root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults=UserDefaults(suiteName:domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName:domain);try? FileManager.default.removeItem(at:root) }
        return NotchModel(shelf:ShelfModel(root:root),preferences:Preferences(defaults:defaults))
    }
    func testCoordinatorOnlyUsesFreshSelectedPlayingMusicWithoutStretch() async {
        await MainActor.run {
            let m=model(),live=m.liveSurface
            func track(_ title:String,_ state:PlaybackState,at:Date)->MusicSnapshot {
                MusicSnapshot(id:title,service:.yandexDesktop,title:title,artist:"Artist",album:"",state:state,duration:200,position:20,commands:[],updatedAt:at)
            }
            live.receiveMusic(track("A",.playing,at:now),now:now)
            XCTAssertEqual(live.presentation.mode,.ambient);XCTAssertNil(live.presentation.right)
            live.receiveMusic(track("B",.playing,at:now),now:now)
            XCTAssertEqual(live.presentation.mode,.ambient);XCTAssertEqual(live.presentation.left?.detail,"B · Artist")
            live.receiveMusic(track("B",.paused,at:now),now:now);XCTAssertEqual(live.presentation.mode,.silent)
            live.receiveMusic(track("A",.playing,at:now),now:now.addingTimeInterval(6));XCTAssertEqual(live.presentation.mode,.silent)
            live.receiveMusic(track("A",.playing,at:now),now:now);live.tick(now:now.addingTimeInterval(6))
            XCTAssertEqual(live.presentation.mode,.silent)
        }
    }
    func testRealShelfSignalsSuppressCompletionAndReflectErrorsWithoutAutoOpening() async throws {
        let m=await MainActor.run { model() }
        let source=FileManager.default.temporaryDirectory.appendingPathComponent("live-fixture-\(UUID()).txt")
        try Data("Live Surface fixture".utf8).write(to:source);defer{try? FileManager.default.removeItem(at:source)}
        await m.shelf.importFiles([source,source.appendingPathComponent("missing")])
        await MainActor.run {
            XCTAssertEqual(m.shelf.items.count,1);XCTAssertEqual(m.liveSurface.engine.handledInWorkspace,2)
            XCTAssertEqual(m.state,.idle);XCTAssertEqual(m.liveSurface.presentation.mode,.ambient)
            XCTAssertEqual(m.liveSurface.presentation.left?.attention,true)
            XCTAssertFalse(m.liveSurface.engine.events.values.contains{$0.key == "completed"})
            m.shelf.error=nil;XCTAssertEqual(m.liveSurface.presentation.mode,.silent)
            m.preferences.liveLeft = .files
            XCTAssertEqual(m.liveSurface.presentation.left?.title,"1");XCTAssertNil(m.liveSurface.presentation.right)
            m.preferences.liveLeft = .auto;XCTAssertEqual(m.liveSurface.presentation.mode,.silent)
        }
    }
    func testRealPanelUsesSameAnchorAndDoesNotMakeAmbientShoulderAnIdleTrigger() async throws {
        try await MainActor.run {
            _=NSApplication.shared;guard !NSScreen.screens.isEmpty else {throw XCTSkip("WindowServer unavailable")}
            let m=model(),c=NotchWindowController(model:m);defer{c.stop()}
            let g=try XCTUnwrap(m.geometry)
            for mode in [LiveSurfaceMode.ambient,.stretch,.peek] {
                let size=LiveSurfaceLayout.footprint(for:mode,geometry:g,shoulders:CGSize(width:56,height:32)).size
                m.surfaceSize=size;c.applyWindowLayout()
                XCTAssertEqual(c.panel.frame.maxY,g.anchor.y,accuracy:0.5)
                XCTAssertEqual(c.panel.frame.midX,g.anchor.x,accuracy:0.5)
                let header=g.headerLayout(for:size),camera=g.cameraRegion(for:size)
                if g.hasNotch {XCTAssertLessThanOrEqual(header.left.maxX,camera.minX);XCTAssertGreaterThanOrEqual(header.right.minX,camera.maxX)}
                let browser=CGPoint(x:g.anchor.x+size.width/2-15,y:g.anchor.y-12)
                let region=NotchPointerRegions(geometry:g,frame:g.frame(for:size),pointer:browser)
                XCTAssertFalse(region.acceptsMouse(in:.idle))
                c.samplePointer(at:browser,now:1,pressed:false);c.samplePointer(at:browser,now:5,pressed:false)
                XCTAssertEqual(m.state,.idle);XCTAssertFalse(m.magnetic)
            }
            c.open(.shelf);m.liveSurface.diagnose(.priorities)
            XCTAssertEqual(m.state,.shelf);XCTAssertEqual(m.liveSurface.presentation.mode,.workspace)
            c.collapse();XCTAssertEqual(m.liveSurface.presentation.mode,.ambient)
        }
    }
}
