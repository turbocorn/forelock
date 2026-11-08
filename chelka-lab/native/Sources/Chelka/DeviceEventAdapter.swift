import AppKit
import Combine
import ChelkaCore

@MainActor final class DeviceEventAdapter:ObservableObject {
    @Published private(set) var power:MacPowerReading?
    @Published private(set) var audio:AudioDevicesReading?
    @Published private(set) var outputError:String?
    let powerMonitor=PowerSourceMonitor()
    let audioMonitor=AudioDeviceMonitor()
    private let live:LiveSurfaceCoordinator
    private var policy=DeviceTransitionPolicy()
    private var pending:DispatchWorkItem?
    private var resync:DispatchWorkItem?
    private var observers:[NSObjectProtocol]=[]
    private var suppressedUntil=Date.distantPast
    private var pendingSuppressed=false
    private var baselineNextAudio=false
    private var explicitOutput:(id:String,expires:Date)?
    private var asleep=false
    private(set) var running=false
    init(live:LiveSurfaceCoordinator) {
        self.live=live
        powerMonitor.changed={ [weak self] value in self?.received(power:value) }
        audioMonitor.changed={ [weak self] value in self?.received(audio:value) }
    }
    func start() {
        guard !running else{return};running=true;asleep=false
        suppressedUntil=Date().addingTimeInterval(2)
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated{self?.willSleep()}
        })
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated{self?.didWake()}
        })
        powerMonitor.start();audioMonitor.start();scheduleResync(after:2)
    }
    func stop() {
        running=false;pending?.cancel();resync?.cancel();pending=nil;resync=nil;baselineNextAudio=false;explicitOutput=nil
        let center=NSWorkspace.shared.notificationCenter;observers.forEach(center.removeObserver);observers=[]
        powerMonitor.stop();audioMonitor.stop();policy.reset()
        power=nil;audio=nil;pendingSuppressed=false
        live.clearDeviceEvents()
    }
    private func received(power value:MacPowerReading?) {
        guard running,!asleep else{return}
        if value != power {power=value};schedule()
    }
    private func received(audio value:AudioDevicesReading?) {
        guard running,!asleep else{return}
        if value != audio {audio=value}
        if let explicit=explicitOutput {
            if explicit.expires<Date() {explicitOutput=nil}
            else if value?.defaultID == explicit.id {pendingSuppressed=true;explicitOutput=nil}
        }
        if baselineNextAudio {baselineNextAudio=false;_ = policy.update(power:power,audio:audio,now:Date(),suppress:true)}
        schedule()
    }
    private func schedule() {
        pendingSuppressed = pendingSuppressed || live.suppressesDeviceExpansion
        pending?.cancel()
        let item=DispatchWorkItem{ [weak self] in MainActor.assumeIsolated{self?.flush()} }
        pending=item;DispatchQueue.main.asyncAfter(deadline:.now()+0.65,execute:item)
        // Data can update immediately; only the reaction is coalesced.
        updateIndicators()
    }
    private func scheduleResync(after delay:Double) {
        resync?.cancel()
        let item=DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,self.running,!self.asleep else{return}
                self.baselineNextAudio=true
                self.powerMonitor.refresh();self.audioMonitor.refresh()
                self.flush(baseline:true)
            }
        }
        resync=item;DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:item)
    }
    private func flush(baseline:Bool=false) {
        guard running,!asleep else{return};pending=nil
        let now=Date(),suppress=baseline || now<suppressedUntil
        let events=policy.update(power:power,audio:audio,now:now,suppress:suppress)
        for var event in events {
            if pendingSuppressed {
                guard event.priority == .reaction else{continue};event.strategy = .attention
            }
            live.ingest(event,now:now)
        }
        pendingSuppressed=false
        if power?.low != true {live.removeDeviceLowAttention()}
    }
    private func updateIndicators() {
        var events:[LiveSurfaceEvent]=[];let now=Date()
        if let p=power,let percent=p.percent {
            events.append(LiveSurfaceEvent(source:.power,key:"battery",priority:p.low ? .reaction : .background,
                strategy:p.low ? .attention : .ambient,category:.battery,createdAt:now,expiresAt:now.addingTimeInterval(120),
                title:"\(percent)%",detail:"MacBook · \(percent)% · \(p.status)",symbol:p.symbol,allowsAuto:p.low,replace:true))
        }
        if let current=audio?.current {
            events.append(LiveSurfaceEvent(source:.audio,key:"output",priority:.background,strategy:.ambient,category:.devices,
                createdAt:now,expiresAt:now.addingTimeInterval(120),title:current.name,detail:"Аудиовыход: "+current.name,
                symbol:current.symbol,allowsAuto:false,replace:true))
        }
        live.setDeviceIndicators(events)
    }
    func selectOutput(_ id:String) {
        explicitOutput=(id,Date().addingTimeInterval(5))
        outputError=audioMonitor.select(id)
        if outputError != nil {explicitOutput=nil}
    }
    func willSleep() {
        guard running else{return};asleep=true;pending?.cancel();resync?.cancel();pending=nil;resync=nil
        pendingSuppressed=false;baselineNextAudio=false;explicitOutput=nil;policy.reset();power=nil;audio=nil;live.clearDeviceEvents()
    }
    func didWake() {
        guard running else{return};asleep=false;policy.reset();pendingSuppressed=false
        suppressedUntil=Date().addingTimeInterval(3)
        powerMonitor.refresh();audioMonitor.refresh();scheduleResync(after:3)
    }
}
