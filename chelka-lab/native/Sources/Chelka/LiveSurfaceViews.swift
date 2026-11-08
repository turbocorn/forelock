import SwiftUI
import AppKit
import ChelkaCore

enum LiveSurfaceMetrics {
    static func ambientText(_ item:LiveSurfaceItem)->String? {
        switch item.category {
        case .files,.battery:return item.title
        case .devices:return item.title.count>16 ? String(item.title.prefix(15))+"…" : item.title
        default:return nil
        }
    }
    static func shoulderWidth(_ p:LiveSurfacePresentation)->CGFloat {
        func width(_ text:String,_ size:CGFloat,_ weight:NSFont.Weight = .regular)->CGFloat {
            (text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight)]).width
        }
        if p.mode == .stretch,let e=p.event {
            let detail=e.count>1 ? "\(e.detail) ×\(e.count)" : e.detail
            return min(224,max(44,ceil(max(width(e.title,11,.medium)+42,width(detail,10)+24))))
        }
        return max(52,[p.left,p.right].compactMap{$0}.map{item in
            ambientText(item).map{min(164,ceil(width($0,10)+38))} ?? 38
        }.max() ?? 52)
    }
}

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

struct LiveSurfaceView: View {
    @ObservedObject var live: LiveSurfaceCoordinator
    let geometry: NotchGeometry?
    let size: CGSize
    private var header: CGFloat { geometry?.headerHeight ?? 38 }
    var body: some View {
        let layout=geometry?.headerLayout(for:size)
        let side=layout?.left.width ?? size.width/2, camera=layout?.camera.width ?? 0
        VStack(spacing:0) {
            HStack(spacing:0) {
                shoulder(left:true).frame(width:side,height:header).clipped()
                Color.clear.frame(width:camera,height:header).allowsHitTesting(false).accessibilityHidden(true)
                shoulder(left:false).frame(width:side,height:header).clipped()
            }
            if live.presentation.mode == .peek,let e=live.presentation.event {
                VStack(alignment:.leading,spacing:8) {
                    Text(e.title).font(.system(size:15,weight:.medium)).lineLimit(1)
                    Text(e.detail).font(.system(size:11)).foregroundStyle(Color.chelkaMuted).lineLimit(2)
                    if e.action != nil { SurfaceButton("Открыть полку",symbol:"tray") {live.act(on:e.id)} }
                }.frame(width:max(0,size.width-40),alignment:.leading).padding(.top,10)
            }
        }.frame(width:size.width,height:size.height,alignment:.top)
            .accessibilityIdentifier("ForelockLiveSurface")
    }
    @ViewBuilder private func shoulder(left:Bool)->some View {
        switch live.presentation.mode {
        case .ambient:
            if let item=left ? live.presentation.left : live.presentation.right {
                HStack(spacing:5) {
                    Image(systemName:item.symbol).font(.system(size:13,weight:.medium))
                    if let text=LiveSurfaceMetrics.ambientText(item) {Text(text).font(.system(size:10).monospacedDigit()).lineLimit(1)}
                }.foregroundStyle(Color.chelkaText).help(item.detail)
                    .accessibilityElement(children:.ignore).accessibilityLabel(item.title+". "+item.detail)
                    .allowsHitTesting(false)
            } else { Color.clear.accessibilityHidden(true) }
        case .stretch:
            if let e=live.presentation.event {
                HStack(spacing:6) {
                    if left {Image(systemName:e.symbol).font(.system(size:11));Text(e.title).font(.system(size:11,weight:.medium))}
                    else {Text(e.count>1 ? "\(e.detail) ×\(e.count)" : e.detail).font(.system(size:10)).foregroundStyle(Color.chelkaMuted)}
                }.lineLimit(1).padding(.horizontal,12).help(e.title+". "+e.detail).allowsHitTesting(false)
            }
        case .peek:
            if left {Text("Forelock").font(.system(size:13,weight:.semibold)).frame(maxWidth:.infinity,alignment:.leading).padding(.leading,12)}
            else {Button {live.dismissCurrent()} label:{Image(systemName:"xmark").font(.system(size:11)).frame(width:28,height:28)}.buttonStyle(.plain).accessibilityLabel("Закрыть событие").frame(maxWidth:.infinity,alignment:.trailing).padding(.trailing,8)}
        case .silent,.workspace:Color.clear.accessibilityHidden(true)
        }
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
            Text("Auto показывает активность. Батарею MacBook и текущий аудиовыход можно закрепить. Заряд AirPods и кейса недоступен.")
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
        case .nothing:return "Ничего"
        }
    }
}
