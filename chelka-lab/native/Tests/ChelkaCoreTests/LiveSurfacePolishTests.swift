import XCTest
import AppKit
import SwiftUI
import ChelkaCore
import ForelockMusic
@testable import Chelka

final class LiveSurfacePolishTests:XCTestCase {
    let now=Date()
    let geometry=NotchGeometry(screenFrame:CGRect(x:0,y:0,width:1800,height:1169),visibleFrame:CGRect(x:0,y:0,width:1800,height:1125),safeTop:38,leftArea:CGRect(x:0,y:1131,width:790,height:38),rightArea:CGRect(x:1010,y:1131,width:790,height:38))
    func presentation(source:LiveSurfaceSource,key:String,title:String,detail:String,symbol:String="headphones",strategy:LiveSurfaceStrategy = .stretch)->LiveSurfacePresentation {
        var e=LiveSurfaceEngine()
        e.ingest(LiveSurfaceEvent(source:source,key:key,priority:.reaction,strategy:strategy,category:source == .power ? .battery : .devices,createdAt:now,expiresAt:now.addingTimeInterval(12),title:title,detail:detail,symbol:symbol,action:strategy == .peek ? .openShelf : nil),now:now,context:LiveSurfaceContext())
        return e.advance(now:now,context:LiveSurfaceContext())
    }
    @MainActor func plan(_ source:LiveSurfaceSource,_ key:String,_ title:String,_ detail:String)->LiveSurfacePlan {
        LiveSurfacePlan.make(presentation(source:source,key:key,title:title,detail:detail))
    }
    func testAllFiveRealMessagesKeepMeaningAndBoundedReadableFootprints() async {
        await MainActor.run {
            let connected=plan(.audio,"connection","Устройство подключено","AirPods Pro")
            XCTAssertEqual(connected.left?.title,"AirPods Pro");XCTAssertEqual(connected.left?.caption,"Подключены");XCTAssertNil(connected.right)
            let route=plan(.audio,"route","Аудиовыход","Динамики MacBook Pro")
            XCTAssertEqual(route.left?.title,"Динамики");XCTAssertEqual(route.left?.caption,"Аудиовыход");XCTAssertNil(route.right)
            let plugged=plan(.power,"supply","Питание подключено","68%")
            XCTAssertEqual(plugged.left?.title,"Питание");XCTAssertEqual(plugged.left?.caption,"Подключено");XCTAssertEqual(plugged.right?.title,"68%")
            XCTAssertFalse(plugged.help.contains("Заряжается"))
            let unplugged=plan(.power,"supply","Работа от батареи","68%")
            XCTAssertEqual(unplugged.left?.title,"От батареи");XCTAssertEqual(unplugged.right?.title,"68%")
            let low=plan(.power,"low","Низкий заряд","10%")
            XCTAssertEqual(low.left?.title,"Низкий заряд");XCTAssertEqual(low.right?.title,"10%")
            for p in [connected,route,plugged,unplugged,low] {
                let f=p.footprint(geometry),r=LiveSurfaceLayout.paintedRect(in:f.size,insets:f.insets,cameraWidth:220)
                XCTAssertEqual(r.width,220+p.shoulders.width+p.shoulders.height,accuracy:0.01)
                XCTAssertLessThan(r.width,430);XCTAssertEqual(f.size.height,38)
                XCTAssertEqual(geometry.frame(for:f.size).maxY,1169)
                XCTAssertTrue(p.ready(size:f.size,painted:r,geometry:geometry))
            }
        }
    }
    func testLongNamesAndCombinedPowerRouteRemainTruthfulWithoutGiantBars() async {
        await MainActor.run {
            let long=plan(.audio,"route","Аудиовыход",String(repeating:"Очень длинное настоящее имя ",count:4))
            XCTAssertLessThanOrEqual(long.shoulders.width,155)
            XCTAssertEqual(long.right,nil);XCTAssertTrue(long.help.contains("настоящее"))
            let combined=plan(.devices,"combined","Питание подключено","68% · Аудиовыход: AirPods Pro (Личное имя)")
            XCTAssertEqual(combined.left?.title,"Питание");XCTAssertEqual(combined.right?.title,"AirPods Pro")
            XCTAssertTrue(combined.right?.caption.contains("68%") == true)
            XCTAssertTrue(combined.right?.caption.contains("Аудиовыход") == true)
            XCTAssertTrue(combined.help.contains("Личное имя"))
        }
    }
    func testOneIndicatorPaintsOnlyOneShoulderAndTwoDoNotMirrorTheWiderOne() {
        let one=LiveSurfaceLayout.footprint(for:.ambient,geometry:geometry,shoulders:CGSize(width:31,height:0))
        let oneRect=LiveSurfaceLayout.paintedRect(in:one.size,insets:one.insets,cameraWidth:220)
        XCTAssertEqual(oneRect.width,251);XCTAssertEqual(oneRect.maxX,one.size.width/2+110)
        let two=LiveSurfaceLayout.footprint(for:.ambient,geometry:geometry,shoulders:CGSize(width:31,height:66))
        let twoRect=LiveSurfaceLayout.paintedRect(in:two.size,insets:two.insets,cameraWidth:220)
        XCTAssertEqual(twoRect.width,317)
        let frame=geometry.frame(for:two.size)
        let empty=CGPoint(x:frame.minX+2,y:frame.maxY-10)
        let region=NotchPointerRegions(geometry:geometry,frame:frame,pointer:empty,paintedBounds:twoRect)
        XCTAssertFalse(region.inSurface);XCTAssertFalse(region.inControls);XCTAssertFalse(region.acceptsMouse(in:.idle))
        XCTAssertFalse(region.acceptsMouse(in:.expanded),"Transparent canvas must not catch even a Peek click")
    }
    func testFadesWaitForSpaceAndInterruptWithoutResettingTheVisibleLayer() {
        var fade=SurfaceContentFade();fade.request("ambient")
        _=fade.step(dt:1.0/60,ready:false,reduced:false);XCTAssertEqual(fade.opacity,0)
        for _ in 0..<10 {_=fade.step(dt:1.0/60,ready:true,reduced:false)}
        XCTAssertEqual(fade.opacity,1);XCTAssertEqual(fade.key,"ambient")
        fade.request("stretch");_=fade.step(dt:1.0/60,ready:true,reduced:false)
        let first=fade.opacity;XCTAssertLessThan(first,1);XCTAssertEqual(fade.key,"ambient")
        fade.request("peek");_=fade.step(dt:1.0/60,ready:true,reduced:false)
        XCTAssertLessThan(fade.opacity,first);XCTAssertEqual(fade.key,"ambient")
        for _ in 0..<20 {_=fade.step(dt:1.0/60,ready:true,reduced:false)}
        XCTAssertEqual(fade.key,"peek");XCTAssertEqual(fade.opacity,1)
        fade.request(nil);for _ in 0..<10 {_=fade.step(dt:1.0/60,ready:true,reduced:false)}
        XCTAssertNil(fade.key);XCTAssertEqual(fade.opacity,0)
    }
    func testReducedMotionShowsFunctionalContentImmediately() {
        var fade=SurfaceContentFade();fade.request("peek")
        _=fade.step(dt:0,ready:false,reduced:true)
        XCTAssertEqual(fade.key,"peek");XCTAssertEqual(fade.opacity,1)
        fade.request(nil);_=fade.step(dt:0,ready:false,reduced:true)
        XCTAssertNil(fade.key);XCTAssertEqual(fade.opacity,0)
    }
    @MainActor private func model()->NotchModel {
        let id="dev.forelock.polish.\(UUID())",defaults=UserDefaults(suiteName:id)!
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(id)
        addTeardownBlock {defaults.removePersistentDomain(forName:id);try? FileManager.default.removeItem(at:root)}
        return NotchModel(shelf:ShelfModel(root:root),preferences:Preferences(defaults:defaults))
    }
    func testAmbientHeartbeatTrackAndPercentageDoNotRestartContentOrResizeValueSlot() async {
        await MainActor.run {
            let m=model()
            func music(_ title:String)->MusicSnapshot {MusicSnapshot(id:"native",service:.appleMusic,title:title,artist:"Artist",album:"",state:.playing,duration:200,position:12,commands:[],updatedAt:now)}
            m.liveSurface.receiveMusic(music("A"),now:now);let key=m.liveSurface.plan.visualKey
            let f=m.liveSurface.plan.footprint(geometry)
            XCTAssertEqual(f.insets.height,31);XCTAssertEqual(f.insets.width,0)
            m.liveSurface.receiveMusic(music("B"),now:now)
            XCTAssertEqual(m.liveSurface.plan.visualKey,key);XCTAssertEqual(m.liveSurface.plan.footprint(geometry),f)
            m.preferences.liveLeft = .battery
            func battery(_ value:String)->LiveSurfaceEvent {LiveSurfaceEvent(source:.power,key:"battery",priority:.background,strategy:.ambient,category:.battery,createdAt:now,expiresAt:now.addingTimeInterval(120),title:value,detail:value,symbol:"battery.50percent",allowsAuto:false,replace:true)}
            m.liveSurface.setDeviceIndicators([battery("9%")]);let small=m.liveSurface.plan
            m.liveSurface.setDeviceIndicators([battery("100%")]);let big=m.liveSurface.plan
            XCTAssertEqual(small.shoulders,big.shoulders);XCTAssertTrue(big.isValueUpdate(from:small))
        }
    }
    func testPeekIsCompactAndItsCameraDoesNotTriggerHover() async throws {
        try await MainActor.run {
            _=NSApplication.shared;guard !NSScreen.screens.isEmpty else{throw XCTSkip("WindowServer unavailable")}
            let m=model(),c=NotchWindowController(model:m);defer{c.stop()}
            m.liveSurface.diagnose(.peek)
            for _ in 0..<120 {c.advanceSurface(dt:1.0/120)}
            XCTAssertEqual(m.state,.idle);XCTAssertEqual(m.liveDisplay.mode,.peek)
            XCTAssertLessThanOrEqual(m.targetSize.height,m.headerHeight+74);XCTAssertLessThan(m.targetSize.width,420)
            XCTAssertEqual(m.liveDisplayOpacity,1)
            let g=m.geometry!,camera=CGPoint(x:g.anchor.x,y:g.anchor.y-15)
            c.samplePointer(at:camera,now:1,pressed:false);c.samplePointer(at:camera,now:5,pressed:false)
            XCTAssertEqual(m.state,.idle);XCTAssertEqual(m.liveSurface.presentation.mode,.peek)
            let f=c.panel.frame
            XCTAssertEqual(f.maxY,g.anchor.y,accuracy:0.5);XCTAssertEqual(f.midX,g.anchor.x,accuracy:0.5)
            m.liveSurface.act(on:m.liveSurface.presentation.event!.id)
            for _ in 0..<120 {c.advanceSurface(dt:1.0/120)}
            XCTAssertEqual(m.state,.shelf);XCTAssertEqual(m.surfaceInsets,.zero)
            XCTAssertEqual(m.liveDisplayOpacity,0);XCTAssertEqual(m.workspaceHeaderOpacity,1)
        }
    }
    func testInterruptedGeometryKeepsTheCameraFixedAndNoPaintOutsideHitMask() async throws {
        try await MainActor.run {
            _=NSApplication.shared;guard !NSScreen.screens.isEmpty else{throw XCTSkip("WindowServer unavailable")}
            let m=model(),c=NotchWindowController(model:m);defer{c.stop()}
            let g=m.geometry!
            m.liveSurface.diagnose(.stretch)
            for step in 0..<180 {
                if step==10 {m.liveSurface.diagnose(.peek)}
                if step==45 {c.open(.overview)}
                if step==80 {c.collapse()}
                c.advanceSurface(dt:1.0/120)
                let f=c.panel.frame,paint=m.paintedBounds,cam=g.cameraRegion(for:m.surfaceSize)
                XCTAssertEqual(f.maxY,g.anchor.y,accuracy:0.5);XCTAssertEqual(f.midX,g.anchor.x,accuracy:0.5)
                if g.hasNotch {
                    XCTAssertLessThanOrEqual(paint.minX,cam.minX+0.1);XCTAssertGreaterThanOrEqual(paint.maxX,cam.maxX-0.1)
                } else {
                    XCTAssertEqual(paint, CGRect(origin: .zero, size: m.surfaceSize))
                }
                XCTAssertGreaterThanOrEqual(m.liveDisplayOpacity,0);XCTAssertLessThanOrEqual(m.liveDisplayOpacity,1)
            }
            m.preferences.reduceMotion=true;m.liveSurface.diagnose(.peek);c.advanceSurface(dt:1.0/60)
            XCTAssertEqual(m.surfaceSize,m.targetSize);XCTAssertEqual(m.surfaceInsets,m.targetInsets);XCTAssertEqual(m.liveDisplayOpacity,1)
        }
    }
    func testNoNotchFallbackRemainsReadableWithoutAnEmptyCameraGap() async {
        await MainActor.run {
            let g=NotchGeometry(screenFrame:CGRect(x:0,y:0,width:1440,height:900),visibleFrame:CGRect(x:0,y:0,width:1440,height:876),safeTop:0,leftArea:nil,rightArea:nil)
            let p=plan(.audio,"route","Аудиовыход","Настоящий выход с длинным именем")
            let f=p.footprint(g)
            XCTAssertEqual(f.insets,.zero);XCTAssertLessThanOrEqual(f.size.width,155)
            XCTAssertGreaterThanOrEqual(f.size.height,32)
            let compact = LiveSurfaceLayout.footprint(for: .stretch, geometry: g, shoulders: CGSize(width: 75, height: 0))
            XCTAssertGreaterThan(compact.size.width - g.idleSize.width, compact.size.height - g.idleSize.height)
            XCTAssertTrue(p.ready(size:f.size,painted:CGRect(origin:.zero,size:f.size),geometry:g))
        }
    }
}
