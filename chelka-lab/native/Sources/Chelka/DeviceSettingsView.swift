import SwiftUI
import AppKit
import ChelkaCore

struct DeviceSettingsView:View {
    @ObservedObject var devices:DeviceEventAdapter
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Питание и звук").font(.system(size:13,weight:.medium))
            if let p=devices.power {
                Text((p.percent.map{"MacBook · \($0)% · "} ?? "MacBook · ")+p.status)
                    .font(.system(size:11)).fixedSize(horizontal:false,vertical:true)
            } else {Text("Данные батареи недоступны").font(.system(size:11)).foregroundStyle(Color.chelkaMuted)}
            AudioOutputMenu(outputs:devices.audio?.outputs ?? [],selected:devices.audio?.defaultID,select:devices.selectOutput)
                .frame(height:28).padding(.horizontal,8)
                .background(Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:7))
            if let connected=devices.audio?.bluetooth,!connected.isEmpty {
                Text("Bluetooth-соединение: "+connected.map(\.name).joined(separator:", "))
                    .font(.system(size:10)).foregroundStyle(Color.chelkaMuted).lineLimit(3)
            }
            if let error=devices.outputError {Text(error).font(.system(size:10)).foregroundStyle(Color.chelkaMuted).lineLimit(3)}
            Text("Выход для основного аудио macOS. Подключение Bluetooth и выбор выхода — разные события.")
                .font(.system(size:10)).foregroundStyle(Color.chelkaMuted).fixedSize(horizontal:false,vertical:true)
        }
    }
}
private struct AudioOutputMenu:NSViewRepresentable {
    let outputs:[AudioOutputReading]
    let selected:String?
    let select:(String)->Void
    func makeCoordinator()->Coordinator {Coordinator(select)}
    func makeNSView(context:Context)->NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:false)
        button.appearance=NSAppearance(named:.darkAqua);button.isBordered=false;button.font = .systemFont(ofSize:12)
        button.menu?.autoenablesItems=false;button.target=context.coordinator;button.action=#selector(Coordinator.choose(_:))
        button.setAccessibilityLabel("Аудиовыход")
        return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {
        context.coordinator.select=select
        let hasCurrent=outputs.contains{$0.id == selected}
        let titles=outputs.map(\.name)+(hasCurrent ? [] : ["Аудиовыход недоступен"])
        if button.itemArray.compactMap({$0.representedObject as? String}) != outputs.map(\.id) || button.itemArray.map(\.title) != titles {
            button.removeAllItems()
            for output in outputs {
                let item=NSMenuItem(title:output.name,action:nil,keyEquivalent:"")
                item.representedObject=output.id;button.menu?.addItem(item)
            }
            if !hasCurrent {let item=NSMenuItem(title:"Аудиовыход недоступен",action:nil,keyEquivalent:"");item.isEnabled=false;button.menu?.addItem(item)}
        }
        button.isEnabled = !outputs.isEmpty
        if let index=outputs.firstIndex(where:{$0.id == selected}) {button.selectItem(at:index)}
        else {button.selectItem(at:outputs.count)}
    }
    final class Coordinator:NSObject {
        var select:(String)->Void
        init(_ select:@escaping(String)->Void) {self.select=select}
        @objc func choose(_ sender:NSPopUpButton) {
            guard let id=sender.selectedItem?.representedObject as? String else{return};select(id)
        }
    }
}
