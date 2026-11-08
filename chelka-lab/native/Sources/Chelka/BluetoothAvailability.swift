import Foundation
import CoreBluetooth

/// Public initialization/authorization only: no scans, pairing or GATT access.
final class BluetoothAvailability:NSObject,CBCentralManagerDelegate,@unchecked Sendable {
    static let shared=BluetoothAvailability()
    static let changed=Notification.Name("ForelockBluetoothAvailability")
    private let lock=NSLock()
    private var started=false,available=false
    private var state=CBManagerState.unknown
    private var central:CBCentralManager?
    var ready:Bool {lock.lock();defer{lock.unlock()};return available}
    var message:String {
        lock.lock();defer{lock.unlock()}
        switch state {case .poweredOn:return "Подключённых аксессуаров нет";case .poweredOff:return "Bluetooth выключен";case .unauthorized:return "Доступ Forelock к Bluetooth не разрешён";case .unsupported:return "Сведения Bluetooth недоступны";case .resetting:return "Bluetooth перезапускается";default:return "Ожидание данных Bluetooth"}
    }
    func start() {
        lock.lock();guard !started else{lock.unlock();return};started=true;lock.unlock()
        let manager=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
        lock.lock();central=manager;lock.unlock()
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        let next=central.state == .poweredOn && CBManager.authorization == .allowedAlways
        lock.lock();let different=available != next || state != central.state;available=next;state=central.state;lock.unlock()
        if different {NotificationCenter.default.post(name:Self.changed,object:nil)}
    }
}
