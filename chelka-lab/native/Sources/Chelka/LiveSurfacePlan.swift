import AppKit
import ChelkaCore

struct LiveCompactBlock:Equatable {
    enum Style:Equatable {case ambient,event,value}
    let symbol:String?
    let title:String
    let caption:String
    let style:Style
    let width:CGFloat
    init(symbol:String?,title:String,caption:String,style:Style) {
        self.symbol=symbol;self.title=title;self.caption=caption;self.style=style
        self.width=Self.measure(symbol:symbol,title:title,caption:caption,style:style)
    }
    private static func measure(symbol:String?,title:String,caption:String,style:Style)->CGFloat {
        func text(_ value:String,_ size:CGFloat,_ weight:NSFont.Weight)->CGFloat {
            (value as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight)]).width
        }
        switch style {
        case .value:return 52 // stable through 9/10/100%; no percentage-driven resize
        case .ambient:
            let label=title.isEmpty ? 0 : title.hasSuffix("%") ? 32 : max(28,min(96,text(title,11,.medium)))
            return ceil(17+(symbol == nil ? 0 : 14)+(label>0 ? 5+label : 0))
        case .event:
            return ceil(20+(symbol == nil ? 0 : 23)+min(112,max(text(title,11.5,.semibold),text(caption,9.5,.regular))))
        }
    }
}
struct LiveSurfacePlan:Equatable {
    var mode:LiveSurfaceMode = .silent
    var left:LiveCompactBlock?
    var right:LiveCompactBlock?
    var title="",detail="",help="",eventID:String?
    var action:LiveSurfaceAction?
    static let empty=LiveSurfacePlan()
    var shoulders:CGSize {CGSize(width:left?.width ?? 0,height:right?.width ?? 0)}
    private(set) var visualKey:String?
    private var peekBodyHeight:CGFloat=0
    private func finalized()->LiveSurfacePlan {
        var p=self
        if mode != .silent && mode != .workspace {
            p.visualKey="\(mode)|\(left.map{String(describing:$0)} ?? "")|\(right.map{String(describing:$0)} ?? "")|\(title)|\(detail)|\(eventID ?? "")|\(action != nil)"
        }
        if mode == .peek {
            let textWidth:CGFloat=344-32-(action == nil ? 0 : 92)
            let detailHeight:CGFloat=detail.isEmpty ? 0 : min(28,ceil((detail as NSString).boundingRect(with:CGSize(width:textWidth,height:100),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:11)]).height))
            p.peekBodyHeight=max(action == nil ? 0 : 32,(title.isEmpty ? 0 : 16)+(detailHeight>0 ? 4+detailHeight : 0))
        }
        return p
    }
    func footprint(_ geometry:NotchGeometry?)->LiveSurfaceFootprint {
        LiveSurfaceLayout.footprint(for:mode,geometry:geometry,shoulders:shoulders,peekSize:CGSize(width:344,height:(geometry?.headerHeight ?? 38)+24+peekBodyHeight))
    }
    func ready(size:CGSize,painted:CGRect,geometry:NotchGeometry?)->Bool {
        if mode == .peek {let target=footprint(geometry).size;return size.height>=target.height-6 && painted.width>=target.width-8}
        let camera=geometry?.hasNotch == false ? 0 : geometry?.neckWidth ?? 220
        if camera==0 {return painted.width+1 >= (shoulders.width+shoulders.height)*0.88}
        let leftRoom=max(0,(size.width-camera)/2-painted.minX)
        let rightRoom=max(0,painted.maxX-(size.width+camera)/2)
        return leftRoom+1 >= (left?.width ?? 0)*0.88 && rightRoom+1 >= (right?.width ?? 0)*0.88
    }
    func isValueUpdate(from old:LiveSurfacePlan)->Bool {
        guard mode == .ambient,old.mode == .ambient else{return false}
        func matches(_ a:LiveCompactBlock?,_ b:LiveCompactBlock?)->Bool {
            if a?.symbol?.hasPrefix("battery.") == true && b?.symbol?.hasPrefix("battery.") == true {return true}
            return a==b
        }
        return matches(left,old.left) && matches(right,old.right)
    }
    static func make(_ p:LiveSurfacePresentation)->LiveSurfacePlan {
        var plan=LiveSurfacePlan();plan.mode=p.mode
        func name(_ value:String)->String {
            if value.localizedCaseInsensitiveContains("macbook") && (value.localizedCaseInsensitiveContains("динамики") || value.localizedCaseInsensitiveContains("speakers")) {return "Динамики"}
            if value.hasPrefix("AirPods"),let parenthesis=value.range(of:" (") {return String(value[..<parenthesis.lowerBound])}
            return value
        }
        func ambient(_ item:LiveSurfaceItem?)->LiveCompactBlock? {
            guard let item else{return nil}
            let label:String
            switch item.category {case .files,.battery:label=item.title;case .devices:label=name(item.title);default:label=""}
            return LiveCompactBlock(symbol:item.symbol,title:label,caption:"",style:.ambient)
        }
        if p.mode == .ambient {plan.left=ambient(p.left);plan.right=ambient(p.right);plan.help=[p.left,p.right].compactMap{$0}.map{$0.title+". "+$0.detail}.joined(separator:"; ");return plan.finalized()}
        guard let e=p.event else{return plan.finalized()}
        plan.help=e.title+". "+e.detail;plan.eventID=e.id;plan.action=e.action
        if p.mode == .peek {plan.title=e.title;plan.detail=e.detail;return plan.finalized()}
        var subject=e.title,caption="",value=""
        if e.id.hasPrefix("audio:route") {subject=name(e.detail);caption="Аудиовыход"}
        else if e.id.hasPrefix("audio:connection") {
            subject=name(e.detail)
            caption=e.title == "Устройство подключено" ? "Подключены" : e.title == "Устройство отключено" ? "Отключены" : "Изменились"
        } else if e.id.hasPrefix("power:") || e.id.hasPrefix("devices:") {
            switch e.title {
            case "Питание подключено":subject="Питание";caption="Подключено"
            case "Питание от сети":subject="Питание";caption="От сети"
            case "Работа от батареи":subject="От батареи";caption="Питание Mac"
            case "Низкий заряд":subject="Низкий заряд";caption="Батарея Mac"
            default:break
            }
            let pieces=e.detail.components(separatedBy:" · ")
            value=pieces.first(where:{$0.hasSuffix("%")}) ?? ""
            if let change=pieces.first(where:{$0.hasPrefix("Аудиовыход: ") || $0.hasPrefix("Устройство подключено: ") || $0.hasPrefix("Устройство отключено: ")}),let colon=change.range(of:": ") {
                let device=name(String(change[colon.upperBound...]))
                let state=change.hasPrefix("Аудиовыход") ? "Аудиовыход" : change.hasPrefix("Устройство отключено") ? "Отключены" : "Подключены"
                plan.right=LiveCompactBlock(symbol:nil,title:device,caption:[value,state].filter{!$0.isEmpty}.joined(separator:" · "),style:.event)
            }
        } else {caption=e.detail}
        if e.count>1 {caption += " ×\(e.count)"}
        plan.left=LiveCompactBlock(symbol:e.symbol,title:subject,caption:caption,style:.event)
        if plan.right == nil,!value.isEmpty {plan.right=LiveCompactBlock(symbol:nil,title:value,caption:"",style:.value)}
        return plan.finalized()
    }
}
