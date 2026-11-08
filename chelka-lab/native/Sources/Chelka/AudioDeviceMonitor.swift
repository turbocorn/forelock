import AppKit
import CoreAudio
import IOBluetooth
import CoreBluetooth
import ChelkaCore

@MainActor final class AudioDeviceMonitor:NSObject {
    private struct Listener {let object:AudioObjectID;var address:AudioObjectPropertyAddress;let block:AudioObjectPropertyListenerBlock}
    private var listeners:[Listener]=[]
    private var connect:IOBluetoothUserNotification?
    private var disconnects:[IOBluetoothUserNotification]=[]
    private var scheduled:DispatchWorkItem?
    private var generation=0
    private var bluetoothAvailability:Any?
    private(set) var running=false
    private(set) var snapshot:AudioDevicesReading?
    private(set) var listenerFailures=0
    var changed:((AudioDevicesReading?)->Void)?
    func start() {
        guard !running else{return};running=true
        bluetoothAvailability=NotificationCenter.default.addObserver(forName:BluetoothAvailability.changed,object:nil,queue:.main) { [weak self] _ in Task{@MainActor in self?.schedule()} }
        BluetoothAvailability.shared.start()
        listen(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDevices)
        listen(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultOutputDevice)
        guard listeners.count==2 else {changed?(nil);return}
        refresh()
    }
    private func listen(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) {
        var address=Self.address(selector,scope)
        let block:AudioObjectPropertyListenerBlock={ [weak self] _,_ in
            Task { @MainActor [weak self] in self?.schedule() }
        }
        if AudioObjectAddPropertyListenerBlock(object,&address,.main,block)==noErr {listeners.append(Listener(object:object,address:address,block:block))}
        else {listenerFailures+=1}
    }
    @objc private func bluetoothChanged(_ note:IOBluetoothUserNotification,device:IOBluetoothDevice) {
        Task { @MainActor [weak self] in guard let self,self.connect != nil else{return};self.schedule() }
    }
    private func schedule() {
        guard running else{return};scheduled?.cancel()
        let item=DispatchWorkItem{[weak self] in MainActor.assumeIsolated{self?.refresh()}}
        scheduled=item;DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:item)
    }
    func refresh() {
        guard running else{return};generation+=1;let ticket=generation
        let needsConnect=connect == nil
        // Metadata only. No audio capture, scanning, pairing or connection requests.
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let audio=Self.readOutputs()
            let observed=Self.readDeviceIDs() ?? []
            let allowed = BluetoothAvailability.shared.ready
            // The first public registration can wait for a CoreBluetooth
            // main-run-loop callback. It must not run inside app launch on main.
            let notification=needsConnect && allowed ? self.flatMap{IOBluetoothDevice.register(forConnectNotifications:$0,selector:#selector(AudioDeviceMonitor.bluetoothChanged(_:device:)))} : nil
            let paired=allowed ? IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] : nil
            let devices=paired?.filter{$0.deviceClassMajor == kBluetoothDeviceClassMajorAudio && $0.name?.isEmpty == false}
            let connected=devices?.filter{$0.isConnected()}.compactMap { device -> BluetoothAudioReading? in
                guard let name=device.name,let id=device.addressString else{return nil}
                return BluetoothAudioReading(id:id,name:String(name.prefix(160)))
            }.sorted{$0.id<$1.id}
            Task { @MainActor [weak self] in
                guard let self,self.running,self.generation == ticket else{notification?.unregister();return}
                if let notification {self.connect?.unregister();self.connect=notification}
                self.disconnects.forEach{$0.unregister()};self.disconnects=[]
                for device in devices ?? [] where device.isConnected() {
                    if let note=device.register(forDisconnectNotification:self,selector:#selector(self.bluetoothChanged(_:device:))) {self.disconnects.append(note)}
                }
                let system=AudioObjectID(kAudioObjectSystemObject)
                for var listener in self.listeners where listener.object != system {
                    AudioObjectRemovePropertyListenerBlock(listener.object,&listener.address,.main,listener.block)
                }
                self.listeners.removeAll{$0.object != system}
                if let audio {
                    for id in observed {
                        self.listen(id,kAudioDevicePropertyDeviceIsAlive)
                        self.listen(id,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput)
                    }
                    for output in audio.outputs {self.listen(output.objectID,kAudioObjectPropertyName)}
                    let next=AudioDevicesReading(outputs:audio.outputs,defaultID:audio.defaultID,bluetooth:connected)
                    self.snapshot=next;self.changed?(next)
                } else {self.snapshot=nil;self.changed?(nil)}
            }
        }
    }
    func stop() {
        if let bluetoothAvailability {NotificationCenter.default.removeObserver(bluetoothAvailability)};bluetoothAvailability=nil
        running=false;generation+=1;scheduled?.cancel();scheduled=nil
        for var listener in listeners {AudioObjectRemovePropertyListenerBlock(listener.object,&listener.address,.main,listener.block)}
        listeners=[];connect?.unregister();connect=nil;disconnects.forEach{$0.unregister()};disconnects=[];snapshot=nil
    }
    /// Revalidates identity before setting the public default media output property.
    func select(_ id:String)->String? {
        guard running,let target=Self.readOutputs()?.outputs.first(where:{$0.id == id}) else{return "Аудиоустройство уже недоступно."}
        var address=Self.address(kAudioHardwarePropertyDefaultOutputDevice),settable:DarwinBoolean=false
        guard AudioObjectIsPropertySettable(AudioObjectID(kAudioObjectSystemObject),&address,&settable)==noErr,settable.boolValue else{return "macOS не разрешает сменить аудиовыход."}
        var object=target.objectID
        let status=AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,UInt32(MemoryLayout.size(ofValue:object)),&object)
        refresh()
        return status == noErr ? nil : "Не удалось сменить аудиовыход (\(status))."
    }
    nonisolated private static func address(_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal)->AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    nonisolated private static func scalar(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector)->UInt32? {
        var a=address(selector),value:UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object,&a,0,nil,&size,&value)==noErr,size == MemoryLayout<UInt32>.size else{return nil};return value
    }
    nonisolated private static func string(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector)->String? {
        var a=address(selector),value:Unmanaged<CFString>?,size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object,&a,0,nil,&size,&value)==noErr,let value else{return nil}
        return value.takeRetainedValue() as String
    }
    nonisolated private static func readDeviceIDs()->[AudioObjectID]? {
        let system=AudioObjectID(kAudioObjectSystemObject)
        var a=address(kAudioHardwarePropertyDevices),size:UInt32=0
        guard AudioObjectGetPropertyDataSize(system,&a,0,nil,&size)==noErr,size<=4096,size%4==0 else{return nil}
        if size==0 {return []}
        var ids=[AudioObjectID](repeating:0,count:Int(size)/4)
        let status=ids.withUnsafeMutableBytes{AudioObjectGetPropertyData(system,&a,0,nil,&size,$0.baseAddress!)}
        guard status==noErr else{return nil}
        return Array(ids.prefix(Int(size)/4))
    }
    nonisolated static func readOutputs()->AudioDevicesReading? {
        guard let ids=readDeviceIDs() else{return nil}
        let outputs=ids.compactMap { id -> AudioOutputReading? in
            guard scalar(id,kAudioDevicePropertyDeviceIsAlive)==1 else{return nil}
            var streams=address(kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput),bytes:UInt32=0
            guard AudioObjectGetPropertyDataSize(id,&streams,0,nil,&bytes)==noErr,bytes>0,
                  let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName),!name.isEmpty else{return nil}
            let transport=scalar(id,kAudioDevicePropertyTransportType)
            return AudioOutputReading(id:uid,objectID:id,name:String(name.prefix(160)),bluetooth:transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
        let current=scalar(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultOutputDevice)
        return AudioDevicesReading(outputs:outputs,defaultID:outputs.first{$0.objectID == current}?.id,bluetooth:nil)
    }
}
