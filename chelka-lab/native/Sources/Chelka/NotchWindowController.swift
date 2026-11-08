import AppKit
import SwiftUI
import ChelkaCore
import Combine

final class NotchPanel: NSPanel {
    var onCancel: (() -> Void)?
    // AppKit normally constrains even a borderless panel below the menu bar.
    // This panel has an explicit screen-top anchor and its own hit-test mask.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class DropHostingView: NSView {
    var accept: (([URL]) -> Void)?
    var acceptsDrag: (() -> Bool)?
    var dragChanged: ((Bool, Int) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func urls(_ info: NSDraggingInfo) -> [URL] {
        guard acceptsDrag?() != false, info.draggingSourceOperationMask.contains(.copy) else { return [] }
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        dragChanged?(true, sender.draggingSequenceNumber)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        dragChanged?(true, sender.draggingSequenceNumber)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { if let sender { dragChanged?(false, sender.draggingSequenceNumber) } }
    override func draggingEnded(_ sender: NSDraggingInfo) { dragChanged?(false, sender.draggingSequenceNumber) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        dragChanged?(false, sender.draggingSequenceNumber)
        accept?(files)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { if let sender { dragChanged?(false, sender.draggingSequenceNumber) } }
}

@MainActor final class NotchWindowController {
    let panel: NotchPanel
    let model: NotchModel
    private var timer: Timer?
    private var globalMouse: Any?
    private var localEvents: Any?
    private var observers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private var spring = SurfaceSpring(CGSize(width: 236, height: 46))
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var pointerPolicy = NotchPointerPolicy()
    private var incomingDragSequence: Int?
    let diagnostics = InteractionDiagnostics()
    private var lastPointerZone: String?
    private var lastFullscreenCheck = 0.0
    private var geometry: NotchGeometry?

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Чёлка"
        panel.identifier = NSUserInterfaceItemIdentifier("ChelkaNotchPanel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // isFloatingPanel resets the level to .floating (3). Set the final level
        // afterwards so the full top surface is above the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.collapse(reason: "escape") }
        let container = DropHostingView(frame: .zero)
        let host = NSHostingView(rootView: NotchRootView(model: model, shelf: model.shelf, preferences: model.preferences))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor), host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor), host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.accept = { [weak model] urls in model?.importFiles(urls, reason: "native-file-drop") }
        container.acceptsDrag = { [weak model] in model?.draggingOut == false && model?.isInteracting == false }
        container.dragChanged = { [weak self] active, sequence in
            self?.nativeFileDrag(active: active, sequence: sequence)
        }
        panel.contentView = container
        model.requestKey = { [weak self] in self?.panel.makeKey() }
        model.onTransition = { [weak self] previous, next, reason in
            guard let self else { return }
            self.record(reason, previous: previous)
            self.pointerPolicy.transitioned(to: next.interactionMode)
            if next == .idle { self.panel.resignKey() }
            else { self.panel.orderFrontRegardless() }
            self.updateMouseRouting(at: NSEvent.mouseLocation)
        }
        reposition()
        panel.orderFrontRegardless()
        installObservers()
        record("controller-start")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func open(_ state: NotchState = .overview) {
        model.open(state, reason: "menu-open")
        panel.orderFrontRegardless()
    }
    func collapse(reason: String = "explicit-close") {
        if !model.close(reason: reason) { record("close-blocked-" + reason) }
    }
    func stop() {
        record("controller-stop")
        timer?.invalidate()
        model.onTransition = nil
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        observers.forEach(NotificationCenter.default.removeObserver)
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        panel.orderOut(nil)
    }
    private func reposition() {
        let screens = NSScreen.screens
        let builtin = screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
        guard let screen = builtin ?? NSScreen.main ?? screens.first else { panel.orderOut(nil); return }
        let next = NotchGeometry(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
                                 leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
        geometry = next
        model.geometry = next
        if !model.state.isOpen { spring = SurfaceSpring(next.idleSize); model.surfaceSize = next.idleSize }
        panel.setFrame(next.frame(for: spring.value), display: true)
        pointerPolicy.resetTimers()
        updateMouseRouting(at: NSEvent.mouseLocation)
        record("screen-reposition")
    }
    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.model.objectWillChange.send() })
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition(); self?.panel.orderFrontRegardless() }
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved]) { [weak self] event in
            guard let self else { return }
            if event.type == .mouseMoved {
                self.updateMouseRouting(at: NSEvent.mouseLocation)
            } else {
                self.mouseDown(at: NSEvent.mouseLocation)
            }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, event.window === self.panel {
                self.collapse(reason: "escape"); return nil
            }
            if event.type == .mouseMoved {
                self.updateMouseRouting(at: NSEvent.mouseLocation)
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                self.mouseDown(at: NSEvent.mouseLocation)
            }
            return event
        }
    }
    private func regions(at point: CGPoint) -> NotchPointerRegions? {
        guard let geometry else { return nil }
        return NotchPointerRegions(geometry: geometry, frame: panel.frame, pointer: point)
    }
    private func updateMouseRouting(at point: CGPoint) {
        panel.ignoresMouseEvents = !(regions(at: point)?.acceptsMouse(in: model.state.interactionMode) ?? false)
    }
    func mouseDown(at point: CGPoint) {
        record("mouse-down", pointer: point)
        guard model.state.isOpen, !model.isInteracting, !model.draggingOut, incomingDragSequence == nil,
              regions(at: point)?.retainsHover != true else { return }
        collapse(reason: "outside-click")
    }
    private func nativeFileDrag(active: Bool, sequence: Int) {
        guard !model.draggingOut else { return }
        if active {
            let began = incomingDragSequence != sequence
            incomingDragSequence = sequence
            model.magnetic = true
            pointerPolicy.resetTimers()
            if began { record("native-file-drag-enter") }
        } else if incomingDragSequence == sequence {
            record("native-file-drag-exit")
            incomingDragSequence = nil
            model.magnetic = false
            model.attraction = 0
            pointerPolicy.resetTimers()
        }
    }
    private func record(_ reason: String, pointer: CGPoint = NSEvent.mouseLocation, previous: NotchState? = nil) {
        let zone = regions(at: pointer)
        diagnostics.record(reason, snapshot: [
            "state": String(describing: model.state), "previousState": previous.map { String(describing: $0) } ?? "",
            "pointer": NSStringFromPoint(pointer), "activeZone": zone.map { NSStringFromRect($0.activation) } ?? "",
            "inActivation": zone?.inActivation ?? false, "inSurface": zone?.inSurface ?? false, "inControls": zone?.inControls ?? false,
            "frame": NSStringFromRect(panel.frame), "targetSize": NSStringFromSize(model.targetSize),
            "hoverSince": pointerPolicy.hoverSince as Any? ?? NSNull(), "outsideSince": pointerPolicy.outsideSince as Any? ?? NSNull(),
            "suppressedUntilExit": pointerPolicy.suppressedUntilExit,
            "pressedButtons": NSEvent.pressedMouseButtons, "ignoresMouseEvents": panel.ignoresMouseEvents,
            "nativeDragSequence": incomingDragSequence as Any? ?? NSNull(), "draggingOut": model.draggingOut,
            "isInteracting": model.isInteracting
        ])
    }
    private func tick() {
        guard let geometry else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick; lastTick = now
        let pointer = NSEvent.mouseLocation
        // Yield to real application-modal file dialogs rather than floating over them.
        let modalPresented = NSApp.modalWindow != nil || (model.isInteracting && !model.shelf.loading)
        let desiredLevel = modalPresented ? NSWindow.Level.floating : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        if panel.level != desiredLevel { panel.level = desiredLevel }
        if incomingDragSequence != nil {
            model.attraction = model.reduceMotion ? 0 : min(18, max(-18, (pointer.x - geometry.anchor.x) * 0.08))
        }
        if now - lastFullscreenCheck > 0.7 {
            lastFullscreenCheck = now
            model.fullscreen = frontmostIsFullscreen(geometry.screenFrame)
            if model.fullscreen && !model.preferences.allowFullscreen && model.state == .hover { collapse(reason: "fullscreen-hover") }
        }
        samplePointer(at: pointer, now: now, pressed: NSEvent.pressedMouseButtons != 0)
        let target = model.targetSize
        if model.reduceMotion {
            if spring.value != target { spring = SurfaceSpring(target); model.surfaceSize = target; panel.setFrame(geometry.frame(for: target), display: true) }
        } else if spring.value != target || spring.velocity != .zero {
            _ = spring.step(toward: target, dt: dt)
            model.surfaceSize = spring.value
            panel.setFrame(geometry.frame(for: spring.value), display: true)
            panel.invalidateShadow()
        }
        updateMouseRouting(at: pointer)
    }
    func samplePointer(at pointer: CGPoint, now: Double, pressed: Bool) {
        guard let zone = regions(at: pointer) else { return }
        let previousTimers = [pointerPolicy.hoverSince, pointerPolicy.outsideSince]
        let action = pointerPolicy.sample(mode: model.state.interactionMode, now: now,
                                          inActivation: zone.inActivation, retainsHover: zone.retainsHover, pressed: pressed,
                                          suspended: model.isInteracting || model.draggingOut || incomingDragSequence != nil ||
                                            (model.state == .idle && model.fullscreen && !model.preferences.allowFullscreen),
                                          hoverEnabled: model.preferences.hoverEnabled, hoverDelay: model.preferences.hoverDelay)
        let name = zone.inActivation ? "physical-notch" : zone.inSurface && model.state != .idle ? "surface" : "outside"
        if name != lastPointerZone || previousTimers != [pointerPolicy.hoverSince, pointerPolicy.outsideSince] {
            lastPointerZone = name
            record("pointer-" + name, pointer: pointer)
        }
        switch action {
        case .openHover: model.open(byHover: true)
        case .closeHover: collapse(reason: "hover-exit-delay")
        case nil: break
        }
    }
    private func frontmostIsFullscreen(_ frame: CGRect) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        // Bounds and owner PID are public window metadata; no screen recording permission or image capture.
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            return rect.width >= frame.width - 2 && rect.height >= frame.height - 2
        }
        return false
    }
}
