import SwiftUI
import ChelkaCore

/// The existing Workspace gets two compact rows; larger inventories scroll
/// inside the same area instead of changing the accepted panel geometry.
struct AccessoryBatteryList:View {
    @ObservedObject var devices:DeviceEventAdapter
    var compact=false
    var body:some View {
        if !devices.accessories.isEmpty {
            ScrollView(.vertical) {
                VStack(spacing:compact ? 0 : 4) {
                    ForEach(devices.accessories) {r in
                        HStack(spacing:5) {
                            Image(systemName:r.symbol).font(.system(size:10)).frame(width:14)
                            Text(r.displayName).lineLimit(1)
                            Spacer(minLength:4)
                            Text(r.summary(at:Date())).monospacedDigit().lineLimit(1)
                                .foregroundStyle(r.fresh(at:Date()) ? Color.chelkaText : Color.chelkaMuted)
                        }.font(.system(size:10)).frame(height:compact ? 12 : 16).help(r.help(at:Date()))
                            .accessibilityElement(children:.ignore).accessibilityLabel(r.displayName+", "+r.summary(at:Date()))
                    }
                }.accessibilityElement(children:.contain)
            }.frame(height:compact ? min(24,CGFloat(devices.accessories.count)*12) : min(36,CGFloat(devices.accessories.count)*20-4))
                .accessibilityLabel("Батареи подключённых аксессуаров, сведения macOS")
        }
    }
}

struct AccessoryBatterySettings:View {
    @ObservedObject var devices:DeviceEventAdapter
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Батареи аксессуаров").font(.system(size:13,weight:.medium))
            if devices.accessories.isEmpty {Text(devices.accessoryMessage).font(.system(size:11)).foregroundStyle(Color.chelkaMuted)}
            else {AccessoryBatteryList(devices:devices)}
            Picker("Для индикатора",selection:Binding(get:{devices.selectedAccessory},set:devices.selectAccessory)) {
                Text("Выберите устройство").tag("")
                ForEach(devices.accessories) {r in Text(r.displayName).tag(r.id)}
                if !devices.selectedAccessory.isEmpty,!devices.accessories.contains(where:{$0.id==devices.selectedAccessory}) {
                    Text("Выбранное устройство недоступно").tag(devices.selectedAccessory)
                }
            }.font(.system(size:11)).pickerStyle(.menu)
            Text("Выберите «Заряд аксессуара» в слоте вокруг камеры. Для AirPods показан меньший из L/R; кейс — только при точной связи с устройством. Сведения сообщает macOS, время аппаратного измерения недоступно.")
                .font(.system(size:10)).foregroundStyle(Color.chelkaMuted).fixedSize(horizontal:false,vertical:true)
        }
    }
}
