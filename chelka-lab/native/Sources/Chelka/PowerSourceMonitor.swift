import Foundation
import IOKit.ps
import ChelkaCore

@MainActor final class PowerSourceMonitor {
    private var source:CFRunLoopSource?
    private(set) var running=false
    var changed:((MacPowerReading?)->Void)?
    func start() {
        guard !running else{return};running=true
        source=IOPSNotificationCreateRunLoopSource({ context in
            guard let context else{return}
            let monitor=Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {monitor.refresh()}
        },Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source {CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)}
        refresh()
    }
    func refresh() {guard running else{return};changed?(source == nil ? nil : Self.read())}
    func stop() {
        running=false
        if let source {CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes);CFRunLoopSourceInvalidate(source)}
        source=nil
    }
    static func read()->MacPowerReading? {
        guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list=IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else{return nil}
        for item in list {
            guard let d=IOPSGetPowerSourceDescription(info,item)?.takeUnretainedValue() as? [String:Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSIsPresentKey] as? Bool != false else {continue}
            return decode(d,adapterPresent:IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil)
        }
        return nil
    }
    static func decode(_ d:[String:Any],adapterPresent:Bool)->MacPowerReading {
        var percent:Int?
        if let current=d[kIOPSCurrentCapacityKey] as? NSNumber,let maximum=d[kIOPSMaxCapacityKey] as? NSNumber,
           maximum.doubleValue.isFinite,current.doubleValue.isFinite,
           maximum.doubleValue>0,current.doubleValue>=0,current.doubleValue<=maximum.doubleValue {
            percent=Int((current.doubleValue/maximum.doubleValue*100).rounded())
        }
        let value=d[kIOPSPowerSourceStateKey] as? String
        let supply:MacPowerSupply=value == kIOPSACPowerValue ? .external : value == kIOPSBatteryPowerValue ? .battery : .unknown
        let plugged:Bool?=adapterPresent || supply == .external ? true : supply == .battery ? false : nil
        return MacPowerReading(percent:percent,supply:supply,adapterConnected:plugged,charging:d[kIOPSIsChargingKey] as? Bool)
    }
}
