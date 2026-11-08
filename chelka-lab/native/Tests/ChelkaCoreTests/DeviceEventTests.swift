import XCTest
import AppKit
import IOKit.ps
import ChelkaCore
@testable import Chelka

final class DeviceEventTests:XCTestCase {
    let now=Date(timeIntervalSince1970:2000)
    func power(_ percent:Int?=68,_ external:Bool=false,_ charging:Bool=false)->MacPowerReading {
        MacPowerReading(percent:percent,supply:external ? .external : .battery,adapterConnected:external,charging:charging)
    }
    func output(_ id:String="speaker",name:String="Динамики MacBook Pro",bluetooth:Bool=false)->AudioOutputReading {
        AudioOutputReading(id:id,objectID:id == "speaker" ? 1 : 2,name:name,bluetooth:bluetooth)
    }
    func audio(_ route:String="speaker",connected:Bool=false,known:Bool=true)->AudioDevicesReading {
        AudioDevicesReading(outputs:[output(),output("pods",name:"AirPods Pro",bluetooth:true)],defaultID:route,
            bluetooth:known ? (connected ? [BluetoothAudioReading(id:"headset",name:"AirPods Pro")] : []) : nil)
    }
    func testInitialDataAndOrdinaryPercentageAndChargingChangesAreSilent() {
        var p=DeviceTransitionPolicy()
        XCTAssertTrue(p.update(power:power(),audio:audio(),now:now).isEmpty)
        XCTAssertTrue(p.update(power:power(67),audio:audio(),now:now).isEmpty)
        XCTAssertEqual(p.update(power:power(67,true,false),audio:audio(),now:now).first?.title,"Питание подключено")
        XCTAssertTrue(p.update(power:power(67,true,true),audio:audio(),now:now).isEmpty)
        XCTAssertEqual(p.update(power:power(67),audio:audio(),now:now).first?.title,"Работа от батареи")
        XCTAssertTrue(p.update(power:power(67),audio:audio(),now:now).isEmpty)
    }
    func testExternalPowerIsNotReportedAsChargingAndInvalidCapacityIsUnknown() async {
        await MainActor.run {
            let d:[String:Any]=[kIOPSCurrentCapacityKey:34,kIOPSMaxCapacityKey:50,kIOPSPowerSourceStateKey:kIOPSACPowerValue,kIOPSIsChargingKey:false]
            let reading=PowerSourceMonitor.decode(d,adapterPresent:false)
            XCTAssertEqual(reading.percent,68);XCTAssertEqual(reading.supply,.external)
            XCTAssertEqual(reading.adapterConnected,true);XCTAssertEqual(reading.charging,false)
            XCTAssertEqual(reading.status,"От сети · не заряжается")
            let unknown=PowerSourceMonitor.decode([kIOPSCurrentCapacityKey:-1,kIOPSMaxCapacityKey:0],adapterPresent:false)
            XCTAssertNil(unknown.percent);XCTAssertNil(unknown.charging);XCTAssertNil(unknown.adapterConnected)
            XCTAssertNil(PowerSourceMonitor.decode([kIOPSCurrentCapacityKey:Double.infinity,kIOPSMaxCapacityKey:Double.infinity],adapterPresent:false).percent)
        }
    }
    func testLowWarningThresholdsHaveHysteresisAndNeverRepeatEachPercent() {
        var p=DeviceTransitionPolicy();_=p.update(power:power(21),audio:nil,now:now)
        let warning=p.update(power:power(20),audio:nil,now:now)
        XCTAssertEqual(warning.count,1);XCTAssertEqual(warning.first?.priority,.reaction);XCTAssertEqual(warning.first?.strategy,.stretch)
        XCTAssertTrue(p.update(power:power(19),audio:nil,now:now).isEmpty)
        _=p.update(power:power(21),audio:nil,now:now)
        XCTAssertTrue(p.update(power:power(20),audio:nil,now:now).isEmpty)
        XCTAssertEqual(p.update(power:power(9),audio:nil,now:now).first?.detail,"9%")
        XCTAssertTrue(p.update(power:power(8),audio:nil,now:now).isEmpty)
        _=p.update(power:power(30,true),audio:nil,now:now)
        _=p.update(power:power(21),audio:nil,now:now)
        XCTAssertEqual(p.update(power:power(20),audio:nil,now:now).first?.key,"low")
        _=p.update(power:power(9,true),audio:nil,now:now)
        XCTAssertEqual(p.update(power:power(9),audio:nil,now:now).first?.priority,.reaction,"Unplugging an already low battery warrants a warning")
        var limited=DeviceTransitionPolicy()
        _=limited.update(power:power(21,true),audio:nil,now:now)
        let weakAdapter=MacPowerReading(percent:19,supply:.battery,adapterConnected:true,charging:false)
        XCTAssertTrue(weakAdapter.low)
        XCTAssertEqual(limited.update(power:weakAdapter,audio:nil,now:now).first?.priority,.reaction)
        XCTAssertTrue(limited.update(power:MacPowerReading(percent:18,supply:.battery,adapterConnected:true,charging:false),audio:nil,now:now).isEmpty)
    }
    func testInitiallyLowAndWakeResyncNeverInventConnectionOrWarningBurst() {
        var p=DeviceTransitionPolicy()
        XCTAssertTrue(p.update(power:power(8),audio:audio("pods",connected:true),now:now).isEmpty)
        XCTAssertTrue(p.update(power:power(7),audio:audio("pods",connected:true),now:now).isEmpty)
        p.reset()
        XCTAssertTrue(p.update(power:power(6,true),audio:audio("speaker"),now:now,suppress:true).isEmpty)
        XCTAssertTrue(p.update(power:power(6,true),audio:audio("pods",connected:true),now:now,suppress:true).isEmpty)
        XCTAssertTrue(p.update(power:power(7,true),audio:audio("pods",connected:true),now:now).isEmpty)
    }
    func testOutputChangeAndBluetoothConnectionHaveDifferentEvidenceAndWording() {
        var p=DeviceTransitionPolicy();_=p.update(power:nil,audio:audio(),now:now)
        let connection=p.update(power:nil,audio:audio(connected:true),now:now)
        XCTAssertEqual(connection.first?.title,"Устройство подключено")
        let route=p.update(power:nil,audio:audio("pods",connected:true),now:now)
        XCTAssertEqual(route.first?.title,"Аудиовыход");XCTAssertEqual(route.first?.detail,"AirPods Pro")
        let back=p.update(power:nil,audio:audio(connected:false),now:now)
        XCTAssertEqual(back.count,1);XCTAssertEqual(back.first?.title,"Аудиовыход");XCTAssertEqual(back.first?.detail,"Динамики MacBook Pro")
        XCTAssertTrue(p.update(power:nil,audio:audio(known:false),now:now).isEmpty)
        XCTAssertTrue(p.update(power:nil,audio:audio(connected:true),now:now).isEmpty,"Restored connection evidence establishes a baseline")
    }
    func testUnknownReadDoesNotBecomeADisconnectAndRecoveryIsSilent() {
        var p=DeviceTransitionPolicy();_=p.update(power:power(),audio:audio("pods",connected:true),now:now)
        XCTAssertTrue(p.update(power:nil,audio:nil,now:now).isEmpty)
        XCTAssertTrue(p.update(power:power(68,true),audio:audio(),now:now).isEmpty)
    }
    func testPowerAndAudioBurstIsOneTruthfulEventWithTTLAndNoPeek() {
        var p=DeviceTransitionPolicy();_=p.update(power:power(),audio:audio(),now:now)
        let events=p.update(power:power(68,true),audio:audio("pods",connected:true),now:now)
        XCTAssertEqual(events.count,1);let e=events[0]
        XCTAssertEqual(e.title,"Питание подключено");XCTAssertTrue(e.detail.contains("68%"));XCTAssertTrue(e.detail.contains("Аудиовыход: AirPods Pro"))
        XCTAssertEqual(e.strategy,.stretch);XCTAssertEqual(e.expiresAt,now.addingTimeInterval(8));XCTAssertTrue(e.replace)
    }
    func testLowAndRouteBurstKeepsReactionPriorityAndSuppressResetsBaselines() {
        var p=DeviceTransitionPolicy();_=p.update(power:power(21),audio:audio(),now:now)
        let events=p.update(power:power(20),audio:audio("pods"),now:now)
        XCTAssertEqual(events.count,1);XCTAssertEqual(events[0].key,"low-combined");XCTAssertEqual(events[0].priority,.reaction)
        XCTAssertTrue(p.update(power:power(70,true),audio:audio(),now:now,suppress:true).isEmpty)
        XCTAssertTrue(p.update(power:power(70,true),audio:audio(),now:now).isEmpty)
    }
    func testDeviceEventsObeyP0AndEqualPriorityDoesNotInterruptCurrentStretch() {
        var p=DeviceTransitionPolicy(),e=LiveSurfaceEngine()
        _=p.update(power:power(),audio:audio(),now:now)
        let powerEvent=p.update(power:power(68,true),audio:audio(),now:now)[0]
        e.ingest(powerEvent,now:now,context:LiveSurfaceContext(workspace:true))
        XCTAssertEqual(e.advance(now:now,context:LiveSurfaceContext()).mode,.silent)
        e.ingest(powerEvent,now:now,context:LiveSurfaceContext());_=e.advance(now:now,context:LiveSurfaceContext())
        let route=p.update(power:power(68,true),audio:audio("pods"),now:now)[0]
        e.ingest(route,now:now.addingTimeInterval(1),context:LiveSurfaceContext())
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(1),context:LiveSurfaceContext()).event?.id,powerEvent.id)
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(2.6),context:LiveSurfaceContext()).event?.id,route.id)
    }
    func testBatteryAndAudioAreOptInDoNotDuplicateAndMusicWinsBackground() {
        var e=LiveSurfaceEngine()
        func ambient(_ source:LiveSurfaceSource,_ key:String,_ category:LiveSurfaceCategory,_ auto:Bool)->LiveSurfaceEvent {
            LiveSurfaceEvent(source:source,key:key,priority:.background,strategy:.ambient,category:category,createdAt:now,expiresAt:now.addingTimeInterval(120),title:key,symbol:"battery.50percent",allowsAuto:auto)
        }
        e.ingest(ambient(.power,"battery",.battery,false),now:now,context:LiveSurfaceContext())
        e.ingest(ambient(.audio,"output",.devices,false),now:now,context:LiveSurfaceContext())
        XCTAssertEqual(e.advance(now:now,context:LiveSurfaceContext()).mode,.silent)
        e.ingest(ambient(.music,"playing",.music,true),now:now,context:LiveSurfaceContext())
        let p=e.advance(now:now,context:LiveSurfaceContext(),left:.battery,right:.auto)
        XCTAssertEqual(p.left?.category,.battery);XCTAssertEqual(p.right?.category,.music)
        XCTAssertNil(e.advance(now:now,context:LiveSurfaceContext(),left:.battery,right:.battery).right)
    }
    func testContentDrivenWidthKeepsFixedCameraAndScreenTop() async {
        await MainActor.run {
            var p=DeviceTransitionPolicy();_=p.update(power:power(),audio:audio(),now:now)
            var e=LiveSurfaceEngine();e.ingest(p.update(power:power(68,true),audio:audio(),now:now)[0],now:now,context:LiveSurfaceContext())
            let presentation=e.advance(now:now,context:LiveSurfaceContext())
            let g=NotchGeometry(screenFrame:CGRect(x:0,y:0,width:1800,height:1169),visibleFrame:CGRect(x:0,y:0,width:1800,height:1125),safeTop:38,leftArea:CGRect(x:0,y:1131,width:790,height:38),rightArea:CGRect(x:1010,y:1131,width:790,height:38))
            let plan=LiveSurfacePlan.make(presentation),footprint=plan.footprint(g),size=footprint.size
            let painted=LiveSurfaceLayout.paintedRect(in:size,insets:footprint.insets,cameraWidth:g.neckWidth)
            XCTAssertEqual(painted.width,g.neckWidth+plan.shoulders.width+plan.shoulders.height)
            XCTAssertLessThan(painted.width,420)
            XCTAssertEqual(size.height,38);XCTAssertEqual(g.frame(for:size).maxY,1169)
            XCTAssertTrue(plan.ready(size:size,painted:painted,geometry:g))
        }
    }
    func testActualPowerAndCoreAudioReadAndPowerObserverCleanup() async throws {
        try await MainActor.run {
            _=NSApplication.shared;guard !NSScreen.screens.isEmpty else {throw XCTSkip("WindowServer unavailable")}
            let p=try XCTUnwrap(PowerSourceMonitor.read(),"MacBook internal battery must be readable on this acceptance Mac")
            XCTAssertTrue((0...100).contains(try XCTUnwrap(p.percent)))
            let audio=try XCTUnwrap(AudioDeviceMonitor.readOutputs());XCTAssertNotNil(audio.current)
            XCTAssertFalse(audio.outputs.isEmpty)
            let monitor=PowerSourceMonitor();var calls=0;monitor.changed={_ in calls+=1};monitor.start()
            XCTAssertEqual(calls,1);monitor.stop();monitor.refresh();XCTAssertEqual(calls,1);XCTAssertFalse(monitor.running)
            print("DEVICE_HARDWARE battery=\(p.percent.map(String.init) ?? "unknown") status=\(p.status) output=\(audio.current?.name ?? "unknown") available=\(audio.outputs.map(\.name).joined(separator:", "))")
        }
    }
}
