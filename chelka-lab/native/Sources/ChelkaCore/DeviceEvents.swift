import Foundation

public enum MacPowerSupply: String, Equatable, Sendable { case battery, external, unknown }
public struct MacPowerReading: Equatable, Sendable {
    public let percent:Int?
    public let supply:MacPowerSupply
    public let adapterConnected:Bool?
    public let charging:Bool?
    public init(percent:Int?,supply:MacPowerSupply,adapterConnected:Bool?,charging:Bool?) {
        self.percent=percent.flatMap{(0...100).contains($0) ? $0 : nil}
        self.supply=supply;self.adapterConnected=adapterConnected;self.charging=charging
    }
    public var low:Bool { supply == .battery && (percent.map{$0<=20} ?? false) }
    public var status:String {
        if charging == true {return "Заряжается"}
        if supply == .external {return "От сети · не заряжается"}
        if adapterConnected == true {return "Адаптер подключён · питание от батареи"}
        if supply == .battery {return "Работа от батареи"}
        return "Режим питания недоступен"
    }
    public var symbol:String {
        if charging == true {return "battery.100percent.bolt"}
        switch percent ?? 100 {case ...10:return "battery.0percent";case ...30:return "battery.25percent";case ...60:return "battery.50percent";case ...85:return "battery.75percent";default:return "battery.100percent"}
    }
}
public struct AudioOutputReading: Equatable, Sendable, Identifiable {
    public let id:String
    public let objectID:UInt32
    public let name:String
    public let bluetooth:Bool
    public init(id:String,objectID:UInt32,name:String,bluetooth:Bool) {self.id=id;self.objectID=objectID;self.name=name;self.bluetooth=bluetooth}
    public var symbol:String {bluetooth ? "headphones" : "speaker.wave.2"}
}
public struct BluetoothAudioReading: Equatable, Sendable, Identifiable {
    public let id:String
    public let name:String
    public init(id:String,name:String) {self.id=id;self.name=name}
}
public struct AudioDevicesReading: Equatable, Sendable {
    public let outputs:[AudioOutputReading]
    public let defaultID:String?
    /// nil means Bluetooth connection evidence is unavailable; [] means none confirmed.
    public let bluetooth:[BluetoothAudioReading]?
    public init(outputs:[AudioOutputReading],defaultID:String?,bluetooth:[BluetoothAudioReading]?) {
        self.outputs=outputs;self.defaultID=defaultID;self.bluetooth=bluetooth
    }
    public var current:AudioOutputReading? {outputs.first{$0.id == defaultID}}
}

/// Compares settled, trustworthy snapshots. Unknown/recovered data establishes a
/// new baseline; absence of evidence is never a disconnect event.
public struct DeviceTransitionPolicy: Sendable {
    private var power:MacPowerReading?
    private var audio:AudioDevicesReading?
    private var warned=Set<Int>()
    public init() {}
    public mutating func reset() {power=nil;audio=nil;warned.removeAll()}
    public mutating func update(power nextPower:MacPowerReading?,audio nextAudio:AudioDevicesReading?,now:Date,suppress:Bool=false)->[LiveSurfaceEvent] {
        var changes:[LiveSurfaceEvent]=[]
        func event(_ source:LiveSurfaceSource,_ key:String,_ title:String,_ detail:String,_ symbol:String,_ priority:LiveSurfacePriority = .information)->LiveSurfaceEvent {
            LiveSurfaceEvent(source:source,key:key,priority:priority,strategy:.stretch,category:source == .power ? .battery : .devices,
                createdAt:now,expiresAt:now.addingTimeInterval(8),title:String(title.prefix(128)),detail:String(detail.prefix(512)),symbol:symbol,replace:true)
        }
        if let next=nextPower {
            let percent=next.percent.map{"\($0)%"} ?? ""
            if next.supply == .external || (next.percent ?? 0)>=25 {warned.removeAll()}
            if let old=power,!suppress {
                if let plugged=next.adapterConnected,let previous=old.adapterConnected,plugged != previous {
                    changes.append(event(.power,"supply",plugged ? "Питание подключено" : "Работа от батареи",percent,plugged ? "powerplug" : next.symbol))
                } else if next.supply != old.supply,next.supply != .unknown,old.supply != .unknown {
                    changes.append(event(.power,"supply",next.supply == .external ? "Питание от сети" : "Работа от батареи",percent,next.symbol))
                }
                if next.low,let current=next.percent,let previous=old.percent,
                   [10,20].contains(where:{current <= $0 && (previous > $0 || old.supply == .external) && !warned.contains($0)}) {
                    warned.formUnion([10,20].filter{current <= $0})
                    changes.removeAll{$0.source == .power}
                    changes.append(event(.power,"low","Низкий заряд",percent,"battery.0percent",.reaction))
                }
            } else if next.low,let current=next.percent {warned.formUnion([10,20].filter{current <= $0})}
        }
        if let next=nextAudio,let old=audio,!suppress {
            let routeChanged=next.current?.id != old.current?.id && next.current != nil && old.current != nil
            if routeChanged,let current=next.current {
                changes.append(event(.audio,"route","Аудиовыход",current.name,current.symbol))
            } else if let current=next.bluetooth,let previous=old.bluetooth {
                let added=current.filter{a in !previous.contains{$0.id == a.id}}
                let removed=previous.filter{a in !current.contains{$0.id == a.id}}
                let changed=added+removed
                if let first=changed.first {
                    let title = added.isEmpty ? "Устройство отключено" : removed.isEmpty ? "Устройство подключено" : "Аудиоустройства"
                    changes.append(event(.audio,"connection",title,first.name+(changed.count>1 ? " +\(changed.count-1)" : ""),"headphones"))
                }
            }
        }
        power=nextPower;audio=nextAudio
        guard !suppress else{return []}
        // One settled burst becomes one Stretch. A route change is never
        // described as Bluetooth connection, even when both facts changed.
        if changes.count>1 {
            changes.sort{$0.priority < $1.priority}
            let first=changes[0]
            let detail=changes.map { e in e.source == .power ? e.detail : e.title+": "+e.detail }.filter{!$0.isEmpty}.joined(separator:" · ")
            var merged=event(.devices,first.key == "low" ? "low-combined" : "combined",first.title,detail,first.symbol,first.priority)
            merged.category=first.category
            return [merged]
        }
        return changes
    }
}
