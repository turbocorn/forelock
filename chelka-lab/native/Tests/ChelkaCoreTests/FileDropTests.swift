import XCTest
import AppKit
import SwiftUI
import ChelkaCore
@testable import Chelka

final class FileDropTests: XCTestCase {
    func testProbeRequiresPressedObservedDragAndResetsAfterRelease() {
        var p = FileDragProbe()
        p.sample(leftPressed: true, nearNotch: true, blocked: false)
        XCTAssertFalse(p.isArmed, "A click or old pasteboard cannot arm the destination")
        p.observeDraggedMouse(); p.sample(leftPressed: true, nearNotch: true, blocked: false)
        XCTAssertTrue(p.isArmed)
        p.sample(leftPressed: true, nearNotch: false, blocked: false); XCTAssertFalse(p.isArmed)
        p.sample(leftPressed: true, nearNotch: true, blocked: true); XCTAssertFalse(p.isArmed)
        p.rejectUntilMouseUp(); p.sample(leftPressed: true, nearNotch: true, blocked: false); XCTAssertFalse(p.isArmed)
        p.sample(leftPressed: false, nearNotch: true, blocked: false)
        p.sample(leftPressed: true, nearNotch: true, blocked: false); XCTAssertFalse(p.isArmed)
    }
    func testCaptureHasDepthWithoutMovingTopAnchorOrCamera() {
        let g = NotchGeometry(screenFrame: CGRect(x: -1000, y: 200, width: 1800, height: 1169), visibleFrame: CGRect(x: -1000, y: 200, width: 1800, height: 1125), safeTop: 38,
                              leftArea: CGRect(x: -1000, y: 1331, width: 790, height: 38), rightArea: CGRect(x: 10, y: 1331, width: 790, height: 38))
        let capture = g.frame(for: FileDropLayout.captureSize(g))
        XCTAssertTrue(capture.contains(CGPoint(x: g.anchor.x + 240, y: g.anchor.y - 180)))
        XCTAssertFalse(g.frame(for: g.idleSize).contains(CGPoint(x: g.anchor.x, y: g.anchor.y - 180)))
        XCTAssertEqual(capture.maxY, g.anchor.y)
        let size = FileDropLayout.surfaceSize(g)
        XCTAssertEqual(g.frame(for: size).midX, g.anchor.x)
        let drop = FileDropLayout.dropRect(in: size, headerHeight: g.headerHeight)
        XCTAssertGreaterThan(drop.height, 120); XCTAssertGreaterThan(drop.width, 400)
        XCTAssertFalse(drop.contains(CGPoint(x: 260, y: 15)))
    }
    func testCanvasPreservesPaintedSizeAndNativeSessionSuspendsHover() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("WindowServer unavailable") }
            let domain = "dev.forelock.drop-test.\(UUID())"
            let defaults = UserDefaults(suiteName: domain)!
            let m = NotchModel(shelf: ShelfModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(domain)), preferences: Preferences(defaults: defaults))
            let c = NotchWindowController(model: m)
            defer { c.stop(); defaults.removePersistentDomain(forName: domain) }
            let g = try XCTUnwrap(m.geometry), v = try XCTUnwrap(c.panel.contentView as? DropHostingView), host = try XCTUnwrap(v.subviews.first)
            c.observeDraggingGesture(); c.sampleDragApproach(at: CGPoint(x:g.anchor.x,y:g.anchor.y-180),leftPressed:true,now:1); c.applyWindowLayout()
            XCTAssertEqual(c.panel.frame.size,FileDropLayout.captureSize(g)); XCTAssertEqual(host.frame.size,g.idleSize)
            XCTAssertEqual(c.panel.frame.maxY-host.frame.minY,g.anchor.y)
            m.open(.hover); c.nativeFileDragEntered(sequence:12,count:2); m.surfaceSize=m.targetSize; c.applyWindowLayout()
            XCTAssertEqual(host.frame.size,FileDropLayout.surfaceSize(g))
            XCTAssertEqual(c.panel.frame.minX + host.frame.midX, g.anchor.x, accuracy: 0.5)
            XCTAssertEqual(c.panel.frame.maxY - host.frame.minY, g.anchor.y, accuracy: 0.5)
            // A render of the production view for visual inspection; this is
            // explicitly not evidence of a physical Finder gesture.
            host.displayIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/0.5/drop-view.png")
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output)
            }
            c.samplePointer(at:CGPoint(x:g.anchor.x,y:g.anchor.y-500),now:100,pressed:false)
            c.samplePointer(at:CGPoint(x:g.anchor.x,y:g.anchor.y-500),now:110,pressed:false)
            XCTAssertEqual(m.state,.hover)
            c.nativeFileDragEnded(sequence:11); XCTAssertTrue(m.magnetic)
            c.nativeFileDragEnded(sequence:12); XCTAssertFalse(m.magnetic); XCTAssertEqual(m.state,.hover)
            c.sampleDragApproach(at:g.anchor,leftPressed:false,now:111); c.applyWindowLayout()
            XCTAssertNil(v.presentationSize,"No inactive oversized destination")
        }
    }
    func testMultiFileCopyOnceAndReturnToPreviousContext() async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("Forelock-drop-\(UUID())")
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let sources=[temp.appendingPathComponent("one.txt"),temp.appendingPathComponent("two.txt")]
        for (i,u) in sources.enumerated() { try Data("fixture \(i)".utf8).write(to:u) }
        for context in [NotchState.idle,.overview] {
            let domain="dev.forelock.drop-model.\(UUID())"
            let m=await MainActor.run { () -> NotchModel in
                let m=NotchModel(shelf:ShelfModel(root:temp.appendingPathComponent(domain)),preferences:Preferences(defaults:UserDefaults(suiteName:domain)!))
                if context != .idle { m.open(context) }
                m.beginFileDrop(count:2);m.cancelFileDrop();XCTAssertEqual(m.state,context);XCTAssertTrue(m.shelf.items.isEmpty)
                m.beginFileDrop(count:2);XCTAssertTrue(m.acceptFileDrop(sources));XCTAssertFalse(m.acceptFileDrop(sources))
                return m
            }
            let deadline=Date().addingTimeInterval(5)
            while await MainActor.run(body:{m.magnetic}) && Date()<deadline { try await Task.sleep(for:.milliseconds(25)) }
            await MainActor.run {
                XCTAssertFalse(m.magnetic);XCTAssertEqual(m.state,context);XCTAssertEqual(m.shelf.items.count,2);XCTAssertFalse(m.isInteracting)
                for item in m.shelf.items { XCTAssertTrue(FileManager.default.fileExists(atPath:m.shelf.url(for:item).path)) }
                UserDefaults(suiteName:domain)!.removePersistentDomain(forName:domain)
            }
            for (i,u) in sources.enumerated() { XCTAssertEqual(try Data(contentsOf:u),Data("fixture \(i)".utf8)) }
        }
    }
    func testFailedCopyDoesNotReportSuccessOrNavigateAway() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Forelock-failed-drop-\(UUID())")
        let domain = "dev.forelock.failed-drop.\(UUID())"
        defer { try? FileManager.default.removeItem(at: temp) }
        let model = await MainActor.run { () -> NotchModel in
            let m = NotchModel(shelf: ShelfModel(root: temp), preferences: Preferences(defaults: UserDefaults(suiteName: domain)!))
            m.open(.overview); m.beginFileDrop(count: 1)
            XCTAssertTrue(m.acceptFileDrop([temp.appendingPathComponent("missing-original.txt")]))
            return m
        }
        let deadline = Date().addingTimeInterval(5)
        while await MainActor.run(body: { model.isInteracting }) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await MainActor.run {
            XCTAssertEqual(model.fileDrop, .complete(added: 0, attempted: 1))
            XCTAssertEqual(model.state, .overview); XCTAssertTrue(model.shelf.items.isEmpty)
            XCTAssertNotNil(model.shelf.error)
            UserDefaults(suiteName: domain)!.removePersistentDomain(forName: domain)
        }
        // Allow the confirmation task to finish before deleting its fixture root.
        while await MainActor.run(body: { model.magnetic }) && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        await MainActor.run { XCTAssertFalse(model.magnetic); XCTAssertEqual(model.state, .overview) }
    }
    func testDestinationUsesSessionFileURLsAndOnlyVisibleDropRect() async {
        await MainActor.run {
            _=NSApplication.shared
            let v=DropHostingView(frame:CGRect(x:0,y:0,width:200,height:200))
            let w=NSWindow(contentRect:v.frame,styleMask:.borderless,backing:.buffered,defer:false);w.contentView=v
            defer { w.orderOut(nil) }
            let info=DropInfo();defer { info.draggingPasteboard.releaseGlobally() }
            let files=[URL(fileURLWithPath:"/tmp/forelock-fixture-one"),URL(fileURLWithPath:"/tmp/forelock-fixture-two")]
            info.draggingPasteboard.writeObjects(files as [NSURL]);var enters=0,commits=0
            v.dragEntered={seq,count in XCTAssertEqual(seq,7);XCTAssertEqual(count,2);enters+=1}
            v.acceptsPoint={$0.x>=20 && $0.y>=40}
            v.accept={urls,_ in XCTAssertEqual(urls,files);commits+=1;return true}
            info.draggingLocation=CGPoint(x:5,y:100)
            XCTAssertEqual(v.draggingEntered(info),[]);XCTAssertEqual(enters,1);XCTAssertFalse(v.performDragOperation(info))
            info.draggingLocation=CGPoint(x:100,y:100)
            XCTAssertEqual(v.draggingUpdated(info),.copy);XCTAssertTrue(v.prepareForDragOperation(info));XCTAssertTrue(v.performDragOperation(info))
            XCTAssertFalse(v.performDragOperation(info));XCTAssertEqual(commits,1)
            info.draggingSequenceNumber=8;info.draggingPasteboard.clearContents();info.draggingPasteboard.writeObjects([URL(string:"https://example.com/tab")! as NSURL])
            XCTAssertEqual(v.draggingEntered(info),[]);XCTAssertFalse(v.prepareForDragOperation(info));XCTAssertEqual(commits,1)
            info.draggingPasteboard.clearContents();info.draggingPasteboard.writeObjects(files as [NSURL]);v.acceptsDrag={false}
            XCTAssertEqual(v.draggingEntered(info),[])
        }
    }
}

@MainActor private final class DropInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow:NSWindow?
    var draggingSourceOperationMask:NSDragOperation = .copy
    var draggingLocation:NSPoint = .zero
    var draggedImageLocation:NSPoint = .zero
    nonisolated var draggedImage:NSImage? { nil }
    let draggingPasteboard=NSPasteboard.withUniqueName()
    var draggingSource:Any?
    var draggingSequenceNumber=7
    var draggingFormation:NSDraggingFormation = .none
    var animatesToDestination=false
    var numberOfValidItemsForDrop=0
    var springLoadingHighlight:NSSpringLoadingHighlight = .none
    func slideDraggedImage(to screenPoint:NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions = [], for view:NSView?, classes classArray:[AnyClass], searchOptions:[NSPasteboard.ReadingOptionKey:Any], using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
}
