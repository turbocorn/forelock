import XCTest
import ChelkaCore
@testable import Chelka

final class AccessoryBatteryTests:XCTestCase {
    // Synthetic locally administered addresses, never captured user identifiers.
    let buds="02:00:00:00:00:01",caseID="02:00:00:00:00:02",mouse="02:00:00:00:00:03"
    let now=Date(timeIntervalSince1970:1000)
    func connection(_ id:String,_ name:String="AirPods Pro",_ kind:AccessoryKind = .headphones)->AccessoryConnection {AccessoryConnection(address:id,name:name,kind:kind)!}
    func profiler(_ rows:[[String:Any]])->Data {try! JSONSerialization.data(withJSONObject:["SPBluetoothDataType":[["device_connected":rows.map{["Same name":$0]}]]])}
    func registry(_ rows:[[String:Any]])->Data {try! PropertyListSerialization.data(fromPropertyList:rows,format:.xml,options:0)}
    func testStrictPercentKeepsZeroAndRejectsSentinelsBooleansAndBadNumbers() {
        for v:Any in [0,"0%"," 0\u{a0}% ",100,"100%"] {XCTAssertNotNil(AccessoryBatteryParser.percent(v))}
        for v:Any in [-1,101,"101%","unknown","24garbage",true,0.5,Double.infinity,""] {XCTAssertNil(AccessoryBatteryParser.percent(v),"\(v)")}
    }
    func testIdentityIsExactAndMalformedNamesAreNeverKeys() {
        XCTAssertEqual(AccessoryIdentity.token(buds.lowercased().replacingOccurrences(of:":",with:"-")),AccessoryIdentity.token(buds))
        XCTAssertNotEqual(AccessoryIdentity.token(buds),AccessoryIdentity.token(caseID))
        XCTAssertEqual(AccessoryIdentity.audioOutputToken(buds+":output"),AccessoryIdentity.token(buds))
        XCTAssertNil(AccessoryIdentity.audioOutputToken(buds+":input"))
        XCTAssertNil(AccessoryIdentity.audioOutputToken("AirPods Pro:output"))
        for s in ["AirPods Pro","02:00:00:00:00","02:00:00:00:00:GG","020000000001"] {XCTAssertNil(AccessoryIdentity.token(s))}
    }
    func testCachedAirPodsAndUnmatchedCaseNeverJoinByIdenticalName() {
        let data=profiler([["device_address":buds,"device_batteryLevelLeft":"100%","device_batteryLevelRight":"99%"],["device_address":caseID,"device_batteryLevelCase":"74%"]])
        let c=connection(buds)
        let r=AccessoryBatteryParser.merge(profiler:data,registry:nil,before:[c],after:[c],now:now)
        XCTAssertEqual(r.count,1);XCTAssertEqual(r[0].values.left,100);XCTAssertEqual(r[0].values.right,99);XCTAssertNil(r[0].values.caseLevel)
        XCTAssertEqual(AccessoryBatteryParser.merge(profiler:data,registry:nil,before:[],after:[],now:now),[])
    }
    func testConnectionDisappearanceAndNewConnectionDuringProbeInvalidateCells() {
        let c=connection(buds),p=profiler([["device_address":buds,"device_batteryLevelLeft":"90%"]])
        XCTAssertTrue(AccessoryBatteryParser.merge(profiler:p,registry:nil,before:[c],after:[],now:now).isEmpty)
        let r=AccessoryBatteryParser.merge(profiler:p,registry:nil,before:[],after:[c],now:now)
        XCTAssertFalse(r[0].values.available);XCTAssertNil(r[0].observedAt)
    }
    func testExactCaseAndHIDZeroArePreservedWithoutMakingAnOverallBudReading() {
        let c=connection(buds),m=connection(mouse,"Mouse",.mouse)
        let p=profiler([["device_address":buds,"device_batteryLevelLeft":0,"device_batteryLevelCase":"0%"]])
        let h=registry([["DeviceAddress":mouse,"BatteryPercent":0,"Transport":"Bluetooth"]])
        let r=AccessoryBatteryParser.merge(profiler:p,registry:h,before:[c,m],after:[c,m],now:now)
        let a=r.first{$0.id==c.id}!,b=r.first{$0.id==m.id}!
        XCTAssertNil(a.values.main);XCTAssertEqual(a.values.left,0);XCTAssertEqual(a.values.caseLevel,0);XCTAssertEqual(b.values.main,0)
    }
    func testConflictingDuplicateCellsAndInvalidValuesRemainUnknown() {
        let c=connection(buds)
        let p=profiler([["device_address":buds,"device_batteryLevelLeft":91,"device_batteryLevelRight":101],["device_address":buds,"device_batteryLevelLeft":92]])
        let r=AccessoryBatteryParser.merge(profiler:p,registry:nil,before:[c],after:[c],now:now)
        XCTAssertFalse(r[0].values.available)
    }
    func testConflictingSourcesAndAmbiguousConnectionsFailClosed() {
        let c=connection(mouse,"Mouse",.mouse)
        let p=profiler([["device_address":mouse,"device_batteryLevelMain":24]])
        let h=registry([["DeviceAddress":mouse,"BatteryPercent":25,"Transport":"Bluetooth"]])
        XCTAssertFalse(AccessoryBatteryParser.merge(profiler:p,registry:h,before:[c],after:[c],now:now)[0].values.available)
        XCTAssertTrue(AccessoryBatteryParser.merge(profiler:p,registry:h,before:[c],after:[c,c],now:now).isEmpty)
    }
    func testTTLAndUnknownDoNotBecomeFreshBecauseDeviceStillExists() {
        let c=connection(buds),r=AccessoryBatteryReading(connection:c,values:AccessoryBatteryValues(left:80,right:90),observedAt:now)
        XCTAssertTrue(r.fresh(at:now.addingTimeInterval(89)));XCTAssertFalse(r.fresh(at:now.addingTimeInterval(90)))
        XCTAssertFalse(r.fresh(at:now.addingTimeInterval(-1)));XCTAssertEqual(r.values.compactPercent,80)
        XCTAssertEqual(r.summary(at:now.addingTimeInterval(90)),"Заряд недоступен")
        XCTAssertFalse(AccessoryBatteryReading(connection:c,values:AccessoryBatteryValues(),observedAt:now).fresh(at:now))
    }
    func testMalformedOrOversizedProbeDoesNotInventLevels() {
        let c=connection(buds)
        for data in [Data("not json".utf8),Data(repeating:32,count:2_097_153)] {
            XCTAssertFalse(AccessoryBatteryParser.merge(profiler:data,registry:data,before:[c],after:[c],now:now)[0].values.available)
        }
    }
    func testAccessoryIsExplicitOptInAndNeverStealsAutoFromMusic() {
        var e=LiveSurfaceEngine()
        e.ingest(LiveSurfaceEvent(source:.devices,key:"accessory-battery",priority:.background,strategy:.ambient,category:.accessory,createdAt:now,expiresAt:now.addingTimeInterval(90),title:"80%",symbol:"airpodspro",allowsAuto:false,replace:true),now:now,context:LiveSurfaceContext())
        XCTAssertEqual(e.advance(now:now,context:LiveSurfaceContext()).mode,.silent)
        XCTAssertEqual(e.advance(now:now,context:LiveSurfaceContext(),left:.accessory).left?.title,"80%")
        XCTAssertEqual(e.advance(now:now.addingTimeInterval(90),context:LiveSurfaceContext(),left:.accessory).mode,.silent)
    }
    func testBatteryUsesTypedPayloadWithoutParsingAUserDeviceName() async {
        await MainActor.run {
            var e=LiveSurfaceEngine()
            var event=LiveSurfaceEvent(source:.audio,key:"route",priority:.information,strategy:.stretch,category:.devices,createdAt:now,expiresAt:now.addingTimeInterval(8),title:"Аудиовыход",detail:"AirPods Pro (Test · 30%)",symbol:"headphones",replace:true)
            event.accessoryBatterySummary="L 99% · R 98%"
            e.ingest(event,now:now,context:LiveSurfaceContext())
            let p=LiveSurfacePlan.make(e.advance(now:now,context:LiveSurfaceContext()))
            XCTAssertEqual(p.left?.title,"AirPods Pro");XCTAssertEqual(p.right?.title,"L 99% · R 98%")
            XCTAssertTrue(p.help.contains("Test · 30%"))
        }
    }
    func testProbeTimeoutAndOversizeTerminateChildWithoutHanging() {
        let r=AccessoryProbeRunner(),start=Date()
        XCTAssertNil(r.run("/bin/sleep",["2"],timeout:0.1));XCTAssertLessThan(Date().timeIntervalSince(start),1.5)
        XCTAssertNil(r.run("/usr/bin/yes",[],timeout:2))
        r.cancel();XCTAssertNil(r.run("/bin/echo",["must not launch"]))
    }
    func testCancellationReapsOnlyCurrentChild() async {
        let r=AccessoryProbeRunner()
        let task=Task.detached {r.run("/bin/sleep",["3"],timeout:4)}
        try? await Task.sleep(for:.milliseconds(100));r.cancel()
        let data=await task.value;XCTAssertNil(data)
    }
    func testNativeMonitorIsOffMainAndStopsWithoutLatePublishing() async {
        let m=await MainActor.run {AccessoryBatteryMonitor()}
        await MainActor.run {m.start()}
        var completed=false
        for _ in 0..<300 {
            if await MainActor.run(body:{m.lastProbeDuration>0}) {completed=true;break}
            try? await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(completed,"Bounded native probe did not complete")
        await MainActor.run {
            XCTAssertGreaterThanOrEqual(m.probeCount,1);XCTAssertLessThanOrEqual(m.probeCount,3,"Registration must not cancel/restart its own baseline")
            print("ACCESSORY_HARDWARE "+m.readings.map{"\($0.displayName): \($0.summary(at:Date()))"}.joined(separator:"; ")+" probeSeconds=\(m.lastProbeDuration)")
            m.changed=nil;m.stop();XCTAssertFalse(m.running);XCTAssertTrue(m.readings.isEmpty)
        }
    }
}
