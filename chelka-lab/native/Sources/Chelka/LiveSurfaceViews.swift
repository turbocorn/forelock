import SwiftUI
import AppKit
import ChelkaCore

/// Same isolated Debug events as the status menu. This also lets native
/// accessibility tools exercise the installed app without a separate window.
struct LiveSurfaceDiagnosticActions: ViewModifier {
    let live: LiveSurfaceCoordinator
    func body(content:Content)->some View {
#if DEBUG
        content.accessibilityElement(children:.contain)
            .accessibilityAction(named:Text("Диагностика: Stretch")) {live.diagnose(.stretch)}
            .accessibilityAction(named:Text("Диагностика: Peek")) {live.diagnose(.peek)}
            .accessibilityAction(named:Text("Диагностика: Приоритеты")) {live.diagnose(.priorities)}
            .accessibilityAction(named:Text("Диагностика: Повторы")) {live.diagnose(.duplicates)}
            .accessibilityAction(named:Text("Диагностика: Очистить")) {live.diagnose(.clear)}
#else
        content
#endif
    }
}

struct LiveSurfaceView:View {
    @ObservedObject var live:LiveSurfaceCoordinator
    let plan:LiveSurfacePlan
    let geometry:NotchGeometry?
    let size:CGSize
    private var header:CGFloat {geometry?.hasNotch == false && plan.mode == .ambient ? 25 : geometry?.headerHeight ?? 38}
    private var camera:CGFloat {geometry?.hasNotch == false ? 0 : geometry?.neckWidth ?? 220}
    var body:some View {
        ZStack(alignment:.topLeading) {
            if plan.mode == .peek {
                Button {live.dismissCurrent()} label:{Image(systemName:"xmark").font(.system(size:11,weight:.medium)).frame(width:28,height:28)}
                    .buttonStyle(.plain).accessibilityLabel("Закрыть событие")
                    .position(x:camera>0 ? size.width/2+camera/2+22 : size.width-24,y:header/2)
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(plan.title).font(.system(size:13,weight:.semibold)).lineLimit(1)
                        if !plan.detail.isEmpty {Text(plan.detail).font(.system(size:11)).foregroundStyle(Color.chelkaMuted).lineLimit(2).fixedSize(horizontal:false,vertical:true)}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    if let id=plan.eventID,plan.action != nil {
                        Button {live.act(on:id)} label:{Text("К полке").font(.system(size:11,weight:.semibold)).frame(width:80,height:32)}
                            .buttonStyle(.plain).background(Color.white.opacity(0.10),in:RoundedRectangle(cornerRadius:9))
                            .accessibilityLabel("Открыть полку")
                    }
                }.frame(width:plan.footprint(geometry).size.width-32,height:plan.footprint(geometry).size.height-header-24)
                    .position(x:size.width/2,y:header+10+(plan.footprint(geometry).size.height-header-24)/2)
            } else {
                let groupStart=(size.width-plan.shoulders.width-plan.shoulders.height)/2
                if let left=plan.left {block(left,leading:true).position(x:camera>0 ? (size.width-camera)/2-left.width/2 : groupStart+left.width/2,y:header/2)}
                if let right=plan.right {block(right,leading:false).position(x:camera>0 ? (size.width+camera)/2+right.width/2 : groupStart+plan.shoulders.width+right.width/2,y:header/2)}
            }
        }.frame(width:size.width,height:size.height,alignment:.topLeading)
            .accessibilityIdentifier("ForelockLiveSurface")
            .help(plan.help)
    }
    private func block(_ item:LiveCompactBlock,leading:Bool)->some View {
        HStack(spacing:item.style == .ambient ? 5 : 7) {
            if let symbol=item.symbol {Image(systemName:symbol).font(.system(size:item.style == .ambient ? 12 : 16,weight:.medium)).frame(width:item.style == .ambient ? 14 : 16)}
            if !item.title.isEmpty {
                VStack(alignment:.leading,spacing:1) {
                    Text(item.title).font(.system(size:item.style == .value ? 13 : item.style == .ambient ? 11 : 11.5,weight:item.style == .event ? .semibold : .medium)).monospacedDigit().lineLimit(1)
                    if !item.caption.isEmpty {Text(item.caption).font(.system(size:9.5)).foregroundStyle(Color(white:0.66)).lineLimit(1)}
                }
            }
        }.padding(.leading,leading ? 10 : 7).padding(.trailing,leading ? 7 : 10)
            .frame(width:item.width,height:header)
            .accessibilityElement(children:.ignore).accessibilityLabel(plan.help)
            .allowsHitTesting(false)
    }
}

struct LiveSurfaceSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var devices:DeviceEventAdapter
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Вокруг камеры").font(.system(size:13,weight:.medium))
            slot("Слева",value:$preferences.liveLeft)
            slot("Справа",value:$preferences.liveRight)
            Toggle("События в fullscreen",isOn:$preferences.allowLiveFullscreen).font(.system(size:11)).toggleStyle(.switch).controlSize(.small).tint(.white)
            Text("Auto показывает активность. Батарею MacBook, аудиовыход и заряд выбранного аксессуара можно закрепить. Неизвестный заряд не занимает слот.")
                .font(.system(size:10)).foregroundStyle(Color.chelkaMuted).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func slot(_ label:String,value:Binding<LiveSlotChoice>)->some View {
        HStack(spacing:12) {
            Text(label).font(.system(size:12)).frame(width:44,alignment:.leading)
            LiveSlotMenu(value:value,label:label,batteryAvailable:devices.power?.percent != nil,audioAvailable:devices.audio?.current != nil).frame(width:210,height:28).padding(.horizontal,8)
                .background(Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:7))
        }
    }
}

/// A local appearance on the new control avoids changing the existing panel,
/// Quick Look, or other accepted AppKit controls to fix SwiftUI Menu's light label.
private struct LiveSlotMenu: NSViewRepresentable {
    @Binding var value:LiveSlotChoice
    let label:String
    let batteryAvailable:Bool
    let audioAvailable:Bool
    func makeNSView(context:Context)->NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:false)
        button.appearance=NSAppearance(named:.darkAqua)
        button.isBordered=false;button.font = .systemFont(ofSize:12)
        button.menu?.autoenablesItems=false
        for (index,choice) in LiveSlotChoice.allCases.enumerated() {
            button.addItem(withTitle:Self.name(choice))
            button.lastItem?.tag=index
        }
        button.target=context.coordinator;button.action=#selector(Coordinator.choose(_:))
        button.setAccessibilityLabel(label)
        return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {
        context.coordinator.value=$value
        for (index,choice) in LiveSlotChoice.allCases.enumerated() {
            button.item(at:index)?.isEnabled = choice == .battery ? batteryAvailable : choice == .devices ? audioAvailable : true
        }
        button.selectItem(withTag:LiveSlotChoice.allCases.firstIndex(of:value) ?? 0)
    }
    func makeCoordinator()->Coordinator {Coordinator($value)}
    final class Coordinator:NSObject {
        var value:Binding<LiveSlotChoice>
        init(_ value:Binding<LiveSlotChoice>) {self.value=value}
        @objc func choose(_ sender:NSPopUpButton) {
            let choices=LiveSlotChoice.allCases,index=sender.selectedTag()
            guard choices.indices.contains(index),sender.selectedItem?.isEnabled == true else{return}
            value.wrappedValue=choices[index]
        }
    }
    private static func name(_ choice:LiveSlotChoice)->String {
        switch choice {
        case .auto:return "Auto"
        case .music:return "Музыка"
        case .files:return "Файлы"
        case .activities:return "Активности"
        case .battery:return "Батарея MacBook"
        case .devices:return "Текущий аудиовыход"
        case .accessory:return "Заряд аксессуара"
        case .nothing:return "Ничего"
        }
    }
}
