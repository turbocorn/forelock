import AppKit
import IOBluetooth
import CoreBluetooth
import ChelkaCore

/// Bounded, serial, off-main probes. No raw output, address or battery history is
/// logged or written to disk. Cancellation kills only our current child process.
final class AccessoryProbeRunner:@unchecked Sendable {
    private let lock=NSLock()
    private var child:Process?
    private var cancelled=false
    func cancel() {
        lock.lock();cancelled=true
        if let child,child.isRunning {kill(child.processIdentifier,SIGKILL)}
        lock.unlock()
    }
    func run(_ path:String,_ arguments:[String],timeout:Double=6)->Data? {
        let process=Process(),pipe=Pipe()
        process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments
        process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        lock.lock()
        guard !cancelled else{lock.unlock();return nil}
        do {try process.run();child=process} catch {lock.unlock();return nil}
        lock.unlock()
        let watchdog=DispatchWorkItem {if process.isRunning {kill(process.processIdentifier,SIGKILL)}}
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+timeout,execute:watchdog)
        var result=Data(),overflow=false
        while let chunk=try? pipe.fileHandleForReading.read(upToCount:8192),!chunk.isEmpty {
            if result.count+chunk.count>2_097_152 {overflow=true;if process.isRunning {kill(process.processIdentifier,SIGKILL)};break}
            result.append(chunk)
        }
        process.waitUntilExit();watchdog.cancel();try? pipe.fileHandleForReading.close()
        lock.lock();child=nil;let stopped=cancelled;lock.unlock()
        return !stopped && !overflow && process.terminationStatus==0 ? result : nil
    }
}

@MainActor final class AccessoryBatteryMonitor:NSObject {
    private let queue=DispatchQueue(label:"dev.forelock.accessory-probe",qos:.utility)
    private var connect:IOBluetoothUserNotification?
    private var disconnects:[IOBluetoothUserNotification]=[]
    private var pending:DispatchWorkItem?,poll:DispatchWorkItem?,expiry:DispatchWorkItem?
    private var runner:AccessoryProbeRunner?
    private var generation=0
    private var bluetoothAvailability:Any?
    private(set) var running=false
    private(set) var readings:[AccessoryBatteryReading]=[]
    private(set) var probeCount=0
    private(set) var lastProbeDuration:Double=0
    var changed:(([AccessoryBatteryReading])->Void)?
    func start() {
        guard !running else{return};running=true
        bluetoothAvailability=NotificationCenter.default.addObserver(forName:BluetoothAvailability.changed,object:nil,queue:.main) { [weak self] _ in Task{@MainActor in self?.requestRefresh()} }
        BluetoothAvailability.shared.start()
        requestRefresh()
    }
    @objc private func connectionChanged(_ note:IOBluetoothUserNotification,device:IOBluetoothDevice) {
        let id=device.addressString.flatMap(AccessoryIdentity.token)
        Task { @MainActor [weak self] in
            // Registration also reports devices that were already connected.
            // The initial probe owns that baseline; cancelling it here would
            // re-register forever before the notification token is installed.
            guard let self,self.running,self.connect != nil else{return}
            // A new connection epoch never inherits a previous epoch's percent.
            if let id {self.publish(self.readings.filter{$0.id != id})}
            self.requestRefresh()
        }
    }
    func requestRefresh() {
        guard running else{return};generation+=1;runner?.cancel();runner=nil
        pending?.cancel();poll?.cancel()
        let ticket=generation
        let item=DispatchWorkItem{ [weak self] in self?.beginProbe(ticket:ticket) }
        pending=item;DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:item)
    }
    private func beginProbe(ticket:Int) {
        guard running,generation==ticket else{return};pending=nil
        let work=AccessoryProbeRunner();runner=work;probeCount+=1
        let needsConnect=connect == nil
        queue.async { [weak self] in
            let start=ProcessInfo.processInfo.systemUptime
            let notification=needsConnect && BluetoothAvailability.shared.ready ? self.flatMap{IOBluetoothDevice.register(forConnectNotifications:$0,selector:#selector(AccessoryBatteryMonitor.connectionChanged(_:device:)))} : nil
            let before=Self.connections()
            // No scans, pairing, GATT connections or access-control workarounds.
            let profiler=before.isEmpty ? nil : work.run("/usr/sbin/system_profiler",["SPBluetoothDataType","-json"])
            let registry=before.isEmpty ? nil : work.run("/usr/sbin/ioreg",["-a","-r","-l","-k","BatteryPercent"])
            let after=Self.connections(),now=Date()
            let values=AccessoryBatteryParser.merge(profiler:profiler,registry:registry,before:before,after:after,now:now)
            let duration=ProcessInfo.processInfo.systemUptime-start
            Task { @MainActor [weak self] in
                guard let self,self.running,self.generation==ticket else{notification?.unregister();return}
                self.runner=nil;self.lastProbeDuration=duration
                if let notification {self.connect?.unregister();self.connect=notification}
                self.disconnects.forEach{$0.unregister()};self.disconnects=[]
                // No IOBluetooth call on main until the utility-side live read
                // has actually succeeded (authorization may still be pending).
                for device in (after.isEmpty ? [] : IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) where device.isConnected() {
                    if let n=device.register(forDisconnectNotification:self,selector:#selector(self.connectionChanged(_:device:))) {self.disconnects.append(n)}
                }
                self.publish(values)
                // One bounded refresh per minute, only while devices are present.
                // Empty/permission-denied inventory waits for a connect event.
                if !after.isEmpty {
                    let poll=DispatchWorkItem { [weak self] in self?.requestRefresh() }
                    self.poll=poll;DispatchQueue.main.asyncAfter(deadline:.now()+60,execute:poll)
                }
            }
        }
    }
    private func publish(_ values:[AccessoryBatteryReading]) {
        readings=values;changed?(values);expiry?.cancel();expiry=nil
        guard let deadline=values.compactMap(\.expiresAt).min() else{return}
        let item=DispatchWorkItem { [weak self] in
            guard let self,self.running else{return}
            let now=Date()
            // Strip stale cells even when the next probe hangs/fails. Successful
            // command execution alone never establishes a live connection.
            self.readings=self.readings.map {r in
                guard r.expiresAt.map({$0<=now}) == true else{return r}
                return AccessoryBatteryReading(opaqueID:r.id,name:r.name,kind:r.kind)
            }
            self.changed?(self.readings)
        }
        expiry=item;DispatchQueue.main.asyncAfter(deadline:.now()+max(0,deadline.timeIntervalSinceNow),execute:item)
    }
    nonisolated static func connections()->[AccessoryConnection] {
        guard BluetoothAvailability.shared.ready else{return []}
        return ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).compactMap {d in
            guard d.isConnected(),let address=d.addressString,let name=d.name,!name.isEmpty else{return nil}
            let kind:AccessoryKind
            if d.deviceClassMajor == kBluetoothDeviceClassMajorAudio {kind = .headphones}
            else if name.localizedCaseInsensitiveContains("trackpad") {kind = .trackpad}
            else if name.localizedCaseInsensitiveContains("keyboard") {kind = .keyboard}
            else if name.localizedCaseInsensitiveContains("mouse") {kind = .mouse}
            else {kind = .other}
            return AccessoryConnection(address:address,name:name,kind:kind)
        }.sorted{$0.address<$1.address}
    }
    func stop() {
        if let bluetoothAvailability {NotificationCenter.default.removeObserver(bluetoothAvailability)};bluetoothAvailability=nil
        running=false;generation+=1;runner?.cancel();runner=nil
        pending?.cancel();poll?.cancel();expiry?.cancel();pending=nil;poll=nil;expiry=nil
        connect?.unregister();connect=nil;disconnects.forEach{$0.unregister()};disconnects=[]
        readings=[];changed?([])
    }
}
