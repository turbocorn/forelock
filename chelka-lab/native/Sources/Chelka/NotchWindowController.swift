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

@MainActor final class NotchWindowController {
    let panel: NotchPanel
    let model: NotchModel
    private var timer: Timer?
    private var globalMouse: Any?
    private var localEvents: Any?
    private var observers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private var spring = SurfaceSpring(CGSize(width: 236, height: 46))
    private var insetSpring=SurfaceSpring(.zero)
    private var lastPaintedInsets=CGSize.zero
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var pointerPolicy = NotchPointerPolicy()
    private var miniShelfPolicy = MiniShelfPointerPolicy()
    private var incomingDragSequence: Int?
    private var dragProbe = FileDragProbe()
    private var dragReleasedAt: Double?
    private var wasMagnetic = false
    let diagnostics = InteractionDiagnostics()
    private var lastPointerZone: String?
    private var lastFullscreenCheck = 0.0
    private var geometry: NotchGeometry?

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Forelock"
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
        host.autoresizingMask = []
        container.addSubview(host)
        container.accept = { [weak self] urls, sequence in
            guard let self, self.incomingDragSequence == sequence else { return false }
            let accepted = self.model.acceptFileDrop(urls)
            if accepted { self.record("native-file-drop-committed") }
            return accepted
        }
        container.acceptsDrag = { [weak self] in
            guard let self else { return false }
            return !self.model.draggingOut && !self.model.isInteracting && !self.model.shelf.loading && !self.dragProbe.isRejected
        }
        container.dragEntered = { [weak self] sequence, count in self?.nativeFileDragEntered(sequence: sequence, count: count) }
        container.dragExited = { [weak self] sequence in
            // Keep the session and its surface while the user moves outside.
            // AppKit's exit is not an end/cancel, including during a resize.
            if self?.incomingDragSequence == sequence { self?.record("native-file-drag-outside") }
        }
        container.dragEnded = { [weak self] sequence in self?.nativeFileDragEnded(sequence: sequence) }
        container.dragRejected = { [weak self] in
            guard let self, self.incomingDragSequence == nil else { return }
            self.dragProbe.rejectUntilMouseUp()
        }
        container.acceptsPoint = { [weak model] point in
            guard let model, model.fileDrop?.isReady == true else { return false }
            return FileDropLayout.dropRect(in: model.surfaceSize, headerHeight: model.headerHeight).contains(point)
        }
        panel.contentView = container
        model.requestKey = { [weak self] in
            self?.panel.makeKey()
            DispatchQueue.main.async { [weak self] in self?.focusShelf() }
        }
        model.requestShelfFocus = { [weak self] in self?.focusShelf() }
        model.onTransition = { [weak self] previous, next, reason in
            guard let self else { return }
            if next == .idle {self.model.liveHandoff=false}
            else if previous == .idle && self.model.liveDisplayOpacity>0 {self.model.liveHandoff=true}
            self.record(reason, previous: previous)
            self.pointerPolicy.transitioned(to: next.interactionMode)
            self.syncLiveSurface()
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
        if model.state == .idle && !model.magnetic && (model.liveSurface.presentation.mode == .peek || model.liveSurface.presentation.mode == .stretch) {
            model.liveSurface.dismissCurrent(); return
        }
        if reason == "escape", model.clearShelfSelection() { record("selection-escape"); return }
        if model.fileDrop?.isReady == true {
            cancelIncomingDrag(); record("file-drag-cancel-" + reason); return
        }
        if !model.close(reason: reason) { record("close-blocked-" + reason) }
    }
    func stop() {
        record("controller-stop")
        timer?.invalidate()
        cancelIncomingDrag()
        model.onTransition = nil
        model.requestShelfFocus = nil
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
        if !model.state.isOpen && !model.magnetic && model.liveSurface.presentation.mode == .silent { spring = SurfaceSpring(next.idleSize); insetSpring=SurfaceSpring(.zero); model.surfaceInsets = .zero; model.surfaceSize = next.idleSize }
        applyWindowLayout()
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
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDragged {
                self.observeDraggingGesture()
            } else if event.type == .leftMouseUp {
                self.dragProbe.reset()
                self.updateMouseRouting(at: NSEvent.mouseLocation)
            } else if event.type == .mouseMoved {
                self.updateMouseRouting(at: NSEvent.mouseLocation)
            } else {
                self.mouseDown(at: NSEvent.mouseLocation)
            }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, event.window === self.panel {
                if self.model.draggingOut { return event }
                self.collapse(reason: "escape"); return nil
            }
            if self.handleShelfKeyDown(event) { return nil }
            if event.type == .mouseMoved {
                self.updateMouseRouting(at: NSEvent.mouseLocation)
            }
            if event.type == .leftMouseUp { self.dragProbe.reset(); self.updateMouseRouting(at: NSEvent.mouseLocation) }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                self.mouseDown(at: NSEvent.mouseLocation)
            }
            return event
        }
    }
    func focusShelf() {
        guard panel.isVisible, model.canUseShelfKeyboard, !model.isInteracting, !model.draggingOut, NSApp.modalWindow == nil else { return }
        func marker(_ view: NSView) -> ShelfFocusView? {
            if let view = view as? ShelfFocusView { return view }
            return view.subviews.compactMap { marker($0) }.first
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        if let content = panel.contentView, let view = marker(content) {
            panel.makeKey(); panel.makeFirstResponder(view)
        }
    }
    @discardableResult func handleShelfKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.window === panel, panel.isKeyWindow, model.canUseShelfKeyboard else { return false }
        let responder = panel.firstResponder
        guard responder is ShelfFocusView || (responder as? DraggableFileView)?.selectionEnabled == true else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.keyCode == 0 || event.charactersIgnoringModifiers?.lowercased() == "a" {
            model.selectAllShelfFiles(); miniShelfPolicy = MiniShelfPointerPolicy(); return true
        }
        return false
    }
    private func regions(at point: CGPoint) -> NotchPointerRegions? {
        guard let geometry else { return nil }
        let frame=surfaceFrame
        let painted=LiveSurfaceLayout.paintedRect(in:frame.size,insets:model.surfaceInsets,cameraWidth:geometry.hasNotch ? geometry.neckWidth : 0)
        return NotchPointerRegions(geometry: geometry, frame:frame, pointer: point, paintedBounds:painted)
    }
    private var surfaceFrame: CGRect {
        guard let size = (panel.contentView as? DropHostingView)?.presentationSize else { return panel.frame }
        return CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
    }
    private func updateMouseRouting(at point: CGPoint) {
        let capture = (dragProbe.isArmed || incomingDragSequence != nil) && NSEvent.pressedMouseButtons & 1 != 0
        let zone = regions(at: point)
        let peek = model.state == .idle && !model.magnetic && model.liveSurface.presentation.mode == .peek && zone?.inControls == true
        panel.ignoresMouseEvents = !(capture || peek || (model.magnetic && zone?.inControls == true) || (zone?.acceptsMouse(in: model.state.interactionMode) ?? false))
    }
    func mouseDown(at point: CGPoint) {
        record("mouse-down", pointer: point)
        guard model.state.isOpen, !model.isInteracting, !model.draggingOut, incomingDragSequence == nil,
              regions(at: point)?.retainsHover != true else { return }
        collapse(reason: "outside-click")
    }
    func observeDraggingGesture() {
        guard !model.draggingOut, !model.isInteracting else { return }
        dragProbe.observeDraggedMouse()
    }
    func sampleDragApproach(at point: CGPoint, leftPressed: Bool, now: Double) {
        guard let geometry else { return }
        dragProbe.sample(leftPressed: leftPressed, nearNotch: FileDropLayout.approachRegion(geometry).contains(point),
                         blocked: model.draggingOut || model.isInteracting || NSApp.modalWindow != nil)
        if !leftPressed {
            if incomingDragSequence != nil {
                if dragReleasedAt == nil { dragReleasedAt = now }
                // Allow the native perform/conclude callbacks to finish first.
                if now - (dragReleasedAt ?? now) > 0.15 { if let sequence = incomingDragSequence { nativeFileDragEnded(sequence: sequence) } }
            }
        } else { dragReleasedAt = nil }
    }
    func nativeFileDragEntered(sequence: Int, count: Int) {
        guard !model.draggingOut, !model.isInteracting, !dragProbe.isRejected else { return }
        let began = incomingDragSequence != sequence
        incomingDragSequence = sequence
        model.beginFileDrop(count: count)
        syncLiveSurface()
        pointerPolicy.resetTimers()
        if began { record("native-file-drag-enter") }
    }
    func nativeFileDragEnded(sequence: Int) {
        guard incomingDragSequence == sequence else { return }
        record("native-file-drag-end")
        incomingDragSequence = nil; dragReleasedAt = nil
        dragProbe.rejectUntilMouseUp()
        model.cancelFileDrop()
        syncLiveSurface()
        pointerPolicy.resetTimers()
    }
    private func cancelIncomingDrag() {
        incomingDragSequence = nil; dragReleasedAt = nil
        dragProbe.rejectUntilMouseUp()
        model.cancelFileDrop(); pointerPolicy.resetTimers()
        syncLiveSurface()
    }
    func applyWindowLayout() {
        guard let geometry, let container = panel.contentView as? DropHostingView else { return }
        let capturing = dragProbe.isArmed || incomingDragSequence != nil
        let visual = geometry.frame(for: model.surfaceSize)
        let frame = capturing ? visual.union(geometry.frame(for: FileDropLayout.captureSize(geometry))) : visual
        let needsLayout = panel.frame != frame || container.presentationSize != (capturing ? model.surfaceSize : nil) || container.subviews.first?.frame.size != model.surfaceSize
        container.presentationSize = capturing ? model.surfaceSize : nil
        let silhouetteChanged=lastPaintedInsets != model.surfaceInsets;lastPaintedInsets=model.surfaceInsets
        if panel.frame != frame {panel.setFrame(frame,display:true);panel.invalidateShadow()}
        else if silhouetteChanged {panel.invalidateShadow()}
        if needsLayout { container.needsLayout = true; container.layoutSubtreeIfNeeded() }
    }
    private func record(_ reason: String, pointer: CGPoint = NSEvent.mouseLocation, previous: NotchState? = nil) {
        let zone = regions(at: pointer)
        diagnostics.record(reason, snapshot: [
            "state": String(describing: model.state), "previousState": previous.map { String(describing: $0) } ?? "",
            "pointer": NSStringFromPoint(pointer), "activeZone": zone.map { NSStringFromRect($0.activation) } ?? "",
            "inActivation": zone?.inActivation ?? false, "inSurface": zone?.inSurface ?? false, "inControls": zone?.inControls ?? false,
            "frame": NSStringFromRect(panel.frame), "targetSize": NSStringFromSize(model.targetSize),
            "surfaceFrame": NSStringFromRect(surfaceFrame), "dragProbeArmed": dragProbe.isArmed,
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
        sampleDragApproach(at: pointer, leftPressed: NSEvent.pressedMouseButtons & 1 != 0, now: now)
        if wasMagnetic && !model.magnetic { pointerPolicy.transitioned(to: model.state.interactionMode) }
        wasMagnetic = model.magnetic
        if now - lastFullscreenCheck > 0.7 {
            lastFullscreenCheck = now
            model.fullscreen = frontmostIsFullscreen(geometry.screenFrame)
            if model.fullscreen && !model.preferences.allowFullscreen && model.state == .hover && !model.magnetic { collapse(reason: "fullscreen-hover") }
        }
        syncLiveSurface()
        model.liveSurface.tick()
        samplePointer(at: pointer, now: now, pressed: NSEvent.pressedMouseButtons != 0)
        advanceSurface(dt:dt)
        updateMouseRouting(at:pointer)
    }
    func advanceSurface(dt:Double) {
        let target=model.targetSize,insets=model.targetInsets
        if model.reduceMotion {
            if spring.value != target || spring.velocity != .zero {spring=SurfaceSpring(target);model.surfaceSize=target}
            if insetSpring.value != insets || insetSpring.velocity != .zero {insetSpring=SurfaceSpring(insets);model.surfaceInsets=insets}
        } else {
            if spring.value != target || spring.velocity != .zero {_=spring.step(toward:target,dt:dt);model.surfaceSize=spring.value}
            if insetSpring.value != insets || insetSpring.velocity != .zero {_=insetSpring.step(toward:insets,dt:dt);model.surfaceInsets=insetSpring.value}
        }
        model.advanceLiveContent(dt:dt)
        if model.liveHandoff,model.workspaceHeaderOpacity>=0.999 {model.liveHandoff=false}
        applyWindowLayout()
    }
    private func syncLiveSurface() {
        let zone=regions(at:NSEvent.mouseLocation)
        model.liveSurface.setContext(workspace:model.state.isOpen || model.magnetic || model.isInteracting || model.shelf.loading || model.draggingOut || incomingDragSequence != nil || dragProbe.isArmed,
                                     fullscreen:model.fullscreen,
                                     peekEngaged:model.liveSurface.presentation.mode == .peek && (zone?.retainsHover == true || NSEvent.pressedMouseButtons != 0))
    }
    func samplePointer(at pointer: CGPoint, now: Double, pressed: Bool) {
        guard let zone = regions(at: pointer) else { return }
        if miniShelfPolicy.shouldDismiss(presentation: model.isMiniShelf ? model.recentDrop?.id : nil, now: now,
                                         inside: zone.retainsHover,
                                         interacting: pressed || model.isInteracting || model.draggingOut || model.shelfPointerInteracting || incomingDragSequence != nil ||
                                            (model.hasShelfSelection && panel.isKeyWindow && !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty)) {
            model.dismissMiniShelf()
            record("mini-shelf-exit-delay", pointer: pointer)
            return
        }
        let previousTimers = [pointerPolicy.hoverSince, pointerPolicy.outsideSince]
        let action = pointerPolicy.sample(mode: model.state.interactionMode, now: now,
                                          inActivation: zone.inActivation, retainsHover: zone.retainsHover, pressed: pressed,
                                          suspended: model.isInteracting || model.draggingOut || model.magnetic || incomingDragSequence != nil ||
                                            (model.state == .idle && model.fullscreen && !model.preferences.allowFullscreen) ||
                                            (model.state == .idle && model.liveSurface.presentation.mode == .peek),
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
