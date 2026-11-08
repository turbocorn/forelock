import Foundation
import CoreFoundation
import CryptoKit

public enum AccessoryKind:String,Sendable {case headphones,mouse,keyboard,trackpad,other
    public var symbol:String {switch self {case .headphones:return "headphones";case .mouse:return "magicmouse";case .keyboard:return "keyboard";case .trackpad:return "trackpad";case .other:return "battery.100percent"}}
}
public enum AccessoryIdentity {
    public static func address(_ raw:String)->String? {
        let s=raw.trimmingCharacters(in:.whitespacesAndNewlines).uppercased().replacingOccurrences(of:"-",with:":")
        let parts=s.split(separator:":",omittingEmptySubsequences:false)
        guard parts.count==6,parts.allSatisfy({$0.count==2 && $0.utf8.allSatisfy{(48...57).contains($0) || (65...70).contains($0)}}) else{return nil}
        return s
    }
    /// Persistent selection is opaque; raw addresses stay inside the local probe.
    public static func token(_ raw:String)->String? {address(raw).map{SHA256.hash(data:Data($0.utf8)).map{String(format:"%02x",$0)}.joined()}}
    /// Public Core Audio UID observed on this Mac. Other opaque UID formats fail
    /// closed; no substring/name fallback or claim about all macOS transports.
    public static func audioOutputToken(_ uid:String)->String? {
        if let exact=token(uid) {return exact}
        guard uid.lowercased().hasSuffix(":output") else{return nil}
        return token(String(uid.dropLast(7)))
    }
}
public struct AccessoryConnection:Equatable,Sendable {
    public let address:String
    public let name:String
    public let kind:AccessoryKind
    public init?(address:String,name:String,kind:AccessoryKind) {
        guard let address=AccessoryIdentity.address(address) else{return nil}
        self.address=address;self.name=String(name.prefix(160));self.kind=kind
    }
    public var id:String {AccessoryIdentity.token(address)!}
}
public struct AccessoryBatteryValues:Equatable,Sendable {
    public var main:Int?,left:Int?,right:Int?,caseLevel:Int?
    public init(main:Int?=nil,left:Int?=nil,right:Int?=nil,caseLevel:Int?=nil) {
        func valid(_ x:Int?)->Int? {x.flatMap{(0...100).contains($0) ? $0 : nil}}
        self.main=valid(main);self.left=valid(left);self.right=valid(right);self.caseLevel=valid(caseLevel)
    }
    public var available:Bool {main != nil || left != nil || right != nil || caseLevel != nil}
    public var summary:String {
        var cells:[String]=[]
        if let main {cells.append("\(main)%")}
        if let left {cells.append("L \(left)%")}
        if let right {cells.append("R \(right)%")}
        if let caseLevel {cells.append("Кейс \(caseLevel)%")}
        return cells.isEmpty ? "Заряд недоступен" : cells.joined(separator:" · ")
    }
    /// Not a fabricated overall reading: Ambient explicitly describes this
    /// derived minimum in help; Workspace always shows the individual cells.
    public var compactPercent:Int? {main ?? [left,right].compactMap{$0}.min() ?? caseLevel}
}
public struct AccessoryBatteryReading:Equatable,Sendable,Identifiable {
    public let id:String,name:String,kind:AccessoryKind
    public let values:AccessoryBatteryValues
    /// When macOS was read with an independently confirmed live connection.
    /// Not a hardware sample timestamp: these public sources do not expose one.
    public let observedAt:Date?
    public let expiresAt:Date?
    public init(connection:AccessoryConnection,values:AccessoryBatteryValues,observedAt:Date?) {
        id=connection.id;name=connection.name;kind=connection.kind;self.values=values
        self.observedAt=values.available ? observedAt : nil
        expiresAt=self.observedAt?.addingTimeInterval(90)
    }
    public init(opaqueID:String,name:String,kind:AccessoryKind) {
        id=opaqueID;self.name=name;self.kind=kind;values=AccessoryBatteryValues();observedAt=nil;expiresAt=nil
    }
    public func fresh(at now:Date)->Bool {guard let observedAt,let expiresAt else{return false};return now>=observedAt && now<expiresAt}
    public func summary(at now:Date)->String {fresh(at:now) ? values.summary : "Заряд недоступен"}
    public var displayName:String {if name.hasPrefix("AirPods"),let r=name.range(of:" ("){return String(name[..<r.lowerBound])};return name}
    public var symbol:String {name.hasPrefix("AirPods Pro") ? "airpodspro" : name.hasPrefix("AirPods") ? "airpods" : kind.symbol}
    public func help(at now:Date)->String {
        guard fresh(at:now),let observedAt else{return name+" · Заряд недоступен"}
        let time=DateFormatter.localizedString(from:observedAt,dateStyle:.none,timeStyle:.medium)
        return name+" · "+values.summary+". Получено от macOS в "+time+"; время аппаратного измерения недоступно."+(values.main == nil && (values.left != nil || values.right != nil) ? " В Ambient — меньший из L/R." : "")
    }
}

/// Independent implementation after researching MacSweep's two-source approach.
/// No name joins, no >100 clamping, no conversion of a real zero to unknown.
public enum AccessoryBatteryParser {
    public static func percent(_ value:Any?)->Int? {
        if let n=value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else{return nil}
            let d=n.doubleValue
            return d.isFinite && d.rounded()==d && (0...100).contains(d) ? Int(d) : nil
        }
        if let s=value as? String {
            let text=s.trimmingCharacters(in:.whitespacesAndNewlines)
            let digits=text.hasSuffix("%") ? String(text.dropLast()).trimmingCharacters(in:.whitespacesAndNewlines) : text
            guard !digits.isEmpty,digits.utf8.allSatisfy({(48...57).contains($0)}),let n=Int(digits),(0...100).contains(n) else{return nil}
            return n
        }
        return nil
    }
    public static func merge(profiler:Data?,registry:Data?,before:[AccessoryConnection],after:[AccessoryConnection],now:Date)->[AccessoryBatteryReading] {
        var profiles:[String:[AccessoryBatteryValues]]=[:],hid:[String:[Int]]=[:]
        if let profiler,profiler.count<=2_097_152,
           let root=(try? JSONSerialization.jsonObject(with:profiler)) as? [String:Any],
           let controllers=root["SPBluetoothDataType"] as? [[String:Any]] {
            for controller in controllers.prefix(8) {
                for entry in (controller["device_connected"] as? [[String:Any]] ?? []).prefix(128) {
                    for value in entry.values {
                        guard let d=value as? [String:Any],let raw=d["device_address"] as? String,let id=AccessoryIdentity.address(raw) else{continue}
                        profiles[id,default:[]].append(AccessoryBatteryValues(main:percent(d["device_batteryLevelMain"]),left:percent(d["device_batteryLevelLeft"]),right:percent(d["device_batteryLevelRight"]),caseLevel:percent(d["device_batteryLevelCase"])))
                    }
                }
            }
        }
        if let registry,registry.count<=2_097_152,let roots=(try? PropertyListSerialization.propertyList(from:registry,format:nil)) as? [[String:Any]] {
            var count=0
            func visit(_ node:[String:Any],_ depth:Int) {
                guard depth<16,count<4096 else{return};count+=1
                if let n=percent(node["BatteryPercent"]),let raw=node["DeviceAddress"] as? String,let id=AccessoryIdentity.address(raw),node["Transport"] as? String == "Bluetooth" {hid[id,default:[]].append(n)}
                for child in node["IORegistryEntryChildren"] as? [[String:Any]] ?? [] {visit(child,depth+1)}
            }
            roots.forEach{visit($0,0)}
        }
        func unique(_ values:[Int])->Int? {let set=Set(values);return set.count==1 ? set.first : nil}
        let uniqueConnections=Dictionary(grouping:after.prefix(128),by:\.address).values.filter{$0.count==1}.compactMap(\.first)
        return uniqueConnections.map {connection in
            let presentBefore=before.filter{$0.address==connection.address}.count==1
            let rows=presentBefore ? profiles[connection.address] ?? [] : []
            // Conflicting duplicate cells are unknown. An unmatched case entry
            // can never be attached to earbuds, even when its name is identical.
            var values=AccessoryBatteryValues(main:unique(rows.compactMap(\.main)),left:unique(rows.compactMap(\.left)),right:unique(rows.compactMap(\.right)),caseLevel:unique(rows.compactMap(\.caseLevel)))
            if presentBefore {values.main=unique(rows.compactMap(\.main)+(hid[connection.address] ?? []))}
            return AccessoryBatteryReading(connection:connection,values:values,observedAt:now)
        }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
}
