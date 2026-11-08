import XCTest
import AppKit
import SwiftUI
import ChelkaCore
@testable import Chelka

final class ShelfSelectionTests: XCTestCase {
    func testToggleRangesOrderingAndSingleUnselectedDrag() {
        let ids=(0..<6).map{_ in UUID()};var s=ShelfSelection()
        s.toggle(ids[1],ordered:ids);s.toggle(ids[4],ordered:ids)
        XCTAssertEqual(s.ids,[ids[1],ids[4]])
        XCTAssertEqual(s.dragIDs(from:ids[1],ordered:ids),[ids[1],ids[4]])
        XCTAssertEqual(s.dragIDs(from:ids[3],ordered:ids),[ids[3]])
        s.range(to:ids[2],ordered:ids,additive:false);XCTAssertEqual(s.ids,Set(ids[2...4]))
        s.range(to:ids[0],ordered:ids,additive:true);XCTAssertEqual(s.ids,Set(ids[0...4]))
        s.toggle(ids[2],ordered:ids);XCTAssertFalse(s.ids.contains(ids[2]))
        s.selectAll(ids);XCTAssertEqual(s.ids,Set(ids))
        s.reconcile(Array(ids.prefix(2)));XCTAssertEqual(s.ids,Set(ids.prefix(2)))
        XCTAssertNil(s.anchor)
    }
    private func fixture(_ count:Int=5) throws -> (URL,[URL]) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Forelock-selection-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let files=try (1...count).map { n -> URL in
            let url=root.appendingPathComponent("Выбор \(n).txt");try Data("Selection fixture \(n)\n".utf8).write(to:url);return url
        }
        return(root,files)
    }
    @MainActor private func model(_ root:URL)->NotchModel {
        let domain="dev.forelock.selection-test.\(UUID())"
        let defaults=UserDefaults(suiteName:domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName:domain) }
        return NotchModel(shelf:ShelfModel(root:root.appendingPathComponent("Shelf")),preferences:Preferences(defaults:defaults))
    }
    private func imported(_ root:URL,_ urls:[URL]) async -> NotchModel {
        let m=await MainActor.run { model(root) };await m.shelf.importFiles(urls)
        await MainActor.run { m.open(.shelf) };return m
    }
    private func waitForWork(_ model:NotchModel) async throws {
        let until=Date().addingTimeInterval(5)
        while await MainActor.run(body:{model.isInteracting}) && Date()<until { try await Task.sleep(for:.milliseconds(20)) }
        await MainActor.run { XCTAssertFalse(model.isInteracting) }
    }
    @MainActor private func controller(_ m:NotchModel) throws -> NotchWindowController {
        _=NSApplication.shared;guard !NSScreen.screens.isEmpty else { throw XCTSkip("WindowServer unavailable") }
        let c=NotchWindowController(model:m)
        addTeardownBlock { await MainActor.run { c.stop() } }
        m.surfaceSize=m.targetSize;c.applyWindowLayout();return c
    }
    func testPlainClickOpensQuickLookAndShiftUsesVisualOrder() async throws {
        let(root,urls)=try fixture();let m=await imported(root,urls)
        await MainActor.run {
            let ids=m.shelf.items.map(\.id)
            m.shelfClick(ids[0],modifiers:.command);m.shelfClick(ids[1],modifiers:.command)
            XCTAssertEqual(m.state,.shelf);XCTAssertEqual(m.selection.ids.count,2)
            m.shelfClick(ids[4],modifiers:.shift);XCTAssertEqual(m.selection.ids,Set(ids[1...4]))
            m.shelfClick(ids[2],modifiers:[]);XCTAssertEqual(m.state,.preview(ids[2]));XCTAssertTrue(m.selection.ids.isEmpty)
            m.backFromPreview();m.shelfClick(ids[0],modifiers:.shift)
            XCTAssertEqual(m.selection.ids,Set(ids[0...2]))
            m.open(.overview);XCTAssertTrue(m.selection.ids.isEmpty)
        }
    }
    func testNativeItemsContainWholeSelectionOrOnlyDraggedUnselectedCopy() async throws {
        let(root,urls)=try fixture();let m=await imported(root,urls)
        await MainActor.run {
            let ordered=m.shelf.items
            m.shelfClick(ordered[0].id,modifiers:.command);m.shelfClick(ordered[2].id,modifiers:.command)
            let entries=m.shelfDragItems(from:ordered[0].id).map{ShelfDragEntry(url:m.shelf.url(for:$0),image:m.shelf.image($0))}
            let native=DraggableFileView.makeDraggingItems(entries,at:CGPoint(x:30,y:30))
            XCTAssertEqual(native.count,2)
            let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
            XCTAssertTrue(board.writeObjects(native.compactMap{$0.item as? NSPasteboardWriting}))
            let actual=(board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
            XCTAssertEqual(actual,entries.map(\.url))
            XCTAssertTrue(actual.allSatisfy{FileManager.default.fileExists(atPath:$0.path) && !urls.contains($0)})
            XCTAssertEqual(m.shelfDragItems(from:ordered[1].id).map(\.id),[ordered[1].id])
            m.selectAllShelfFiles();XCTAssertEqual(m.shelfDragItems(from:ordered[0].id).count,5)
            XCTAssertEqual(m.shelf.items.count,5)
        }
    }
    func testCancelledDragDoesNotOpenFileOrToggleSelectionOnLateMouseUp() async throws {
        try await MainActor.run {
            let v=DraggableFileView();var clicks:[NSEvent.ModifierFlags]=[],drag:[Bool]=[]
            v.click={clicks.append($0)};v.dragChanged={drag.append($0)}
            let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:.command,timestamp:1,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1))
            let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:.zero,modifierFlags:[],timestamp:2,windowNumber:0,context:nil,eventNumber:2,clickCount:1,pressure:0))
            v.mouseDown(with:down);v.dragDidBegin();v.dragDidEnd();v.mouseUp(with:up)
            XCTAssertEqual(drag,[true,false]);XCTAssertTrue(clicks.isEmpty)
            v.mouseDown(with:down);v.mouseUp(with:up);XCTAssertEqual(clicks,[.command])
        }
    }
    func testKeyboardRequiresKeyShelfResponderAndEscapeClearsBeforeClosing() async throws {
        let(root,urls)=try fixture();let m=await imported(root,urls)
        try await MainActor.run {
            let c=try controller(m);c.focusShelf()
            XCTAssertTrue(c.panel.isKeyWindow);XCTAssertTrue(c.panel.firstResponder is ShelfFocusView)
            let a=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:1,windowNumber:c.panel.windowNumber,context:nil,characters:"a",charactersIgnoringModifiers:"a",isARepeat:false,keyCode:0))
            XCTAssertTrue(c.handleShelfKeyDown(a));XCTAssertEqual(m.selection.ids.count,5)
            c.collapse(reason:"escape");XCTAssertTrue(m.selection.ids.isEmpty);XCTAssertEqual(m.state,.shelf)
            let text=NSTextView(frame:CGRect(x:0,y:0,width:100,height:30));c.panel.contentView!.addSubview(text);c.panel.makeFirstResponder(text)
            XCTAssertFalse(c.handleShelfKeyDown(a));XCTAssertTrue(m.selection.ids.isEmpty)
            text.removeFromSuperview();c.focusShelf();m.open(.overview)
            XCTAssertFalse(c.handleShelfKeyDown(a));m.open(.shelf);c.collapse(reason:"escape");XCTAssertEqual(m.state,.idle)
        }
    }
    func testBulkRemovalPreservesOriginalsAndUnselectedCopiesAndFailuresKeepSelection() async throws {
        let(root,urls)=try fixture();let m=await imported(root,urls)
        let chosen=await MainActor.run { () -> [ShelfItem] in
            let chosen=Array(m.shelf.items.prefix(3));chosen.forEach{m.shelfClick($0.id,modifiers:.command)};m.deleteSelectedCopies();return chosen
        }
        try await waitForWork(m)
        await MainActor.run {
            XCTAssertEqual(m.shelf.items.count,2);XCTAssertTrue(m.selection.ids.isEmpty)
            for item in chosen { XCTAssertFalse(FileManager.default.fileExists(atPath:m.shelf.url(for:item).path)) }
        }
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath:url.path)) }
        let restored=try await m.shelf.repository.load();XCTAssertEqual(restored.count,2)
        let index=root.appendingPathComponent("Shelf/shelf.json"),originalIndex=try Data(contentsOf:index)
        try Data("damaged fixture index".utf8).write(to:index)
        await MainActor.run { m.selectAllShelfFiles();m.deleteSelectedCopies() }
        try await waitForWork(m)
        await MainActor.run { XCTAssertEqual(m.selection.ids.count,2);XCTAssertEqual(m.shelf.items.count,2);XCTAssertNotNil(m.selectionError) }
        try originalIndex.write(to:index)
    }
    func testMiniSelectAllIncludesOverflowAndSelectionOrDragInteractionRetainsSurface() async throws {
        let(root,urls)=try fixture();let m=await MainActor.run { model(root) }
        await MainActor.run { m.beginFileDrop(count:urls.count);XCTAssertTrue(m.acceptFileDrop(urls)) }
        try await waitForWork(m)
        try await MainActor.run {
            let c=try controller(m);let first=try XCTUnwrap(m.miniShelfItems.first)
            m.shelfClick(first.id,modifiers:.command);m.selectAllShelfFiles()
            XCTAssertEqual(m.selection.ids.count,5);XCTAssertEqual(m.miniShelfOverflow,2)
            XCTAssertEqual(m.shelfDragItems(from:first.id).count,5)
            let g=m.geometry!,outside=CGPoint(x:g.anchor.x,y:g.anchor.y-500)
            m.shelfPointerInteracting=true;c.samplePointer(at:outside,now:1,pressed:false);c.samplePointer(at:outside,now:50,pressed:false)
            XCTAssertEqual(m.state,.miniShelf)
            m.shelfPointerInteracting=false;m.draggingOut=true;c.samplePointer(at:outside,now:80,pressed:false);XCTAssertEqual(m.state,.miniShelf)
            m.draggingOut=false;m.open(.shelf);XCTAssertEqual(m.selection.ids.count,5)
            c.samplePointer(at:outside,now:100,pressed:false);c.samplePointer(at:outside,now:150,pressed:false);XCTAssertEqual(m.state,.shelf)
        }
    }
    func testMiniRemovalTouchesOnlyChosenRecentCopies() async throws {
        let(root,urls)=try fixture();let m=await imported(root,Array(urls.prefix(2)))
        await MainActor.run { m.beginFileDrop(count:3);XCTAssertTrue(m.acceptFileDrop(Array(urls.suffix(3)))) }
        try await waitForWork(m)
        await MainActor.run {
            XCTAssertEqual(m.recentItems.count,3)
            m.recentItems.prefix(2).forEach{m.shelfClick($0.id,modifiers:.command)}
            m.deleteSelectedCopies()
        }
        try await waitForWork(m)
        await MainActor.run {
            XCTAssertEqual(m.state,.miniShelf);XCTAssertEqual(m.recentItems.count,1);XCTAssertEqual(m.shelf.items.count,3)
            XCTAssertTrue(m.selection.ids.isEmpty);m.selectAllShelfFiles();XCTAssertEqual(m.selection.ids.count,1)
            XCTAssertEqual(m.shelfDragItems(from:m.recentItems[0].id).count,1)
        }
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath:url.path)) }
    }
    func testSelectionViewsRenderAndExposeNativeAccessibleToggle() async throws {
        let(root,urls)=try fixture();let m=await imported(root,urls)
        let c=try await MainActor.run { try controller(m) }
        try await MainActor.run {
            let tile=try XCTUnwrap(descendants(c.panel.contentView!).compactMap{$0 as? DraggableFileView}.first)
            let action=try XCTUnwrap(tile.accessibilityCustomActions()?.first)
            XCTAssertTrue(action.handler?() == true);XCTAssertEqual(m.selection.ids.count,1)
            m.selectAllShelfFiles()
        }
        try await Task.sleep(for:.milliseconds(150))
        try await MainActor.run { try capture(c,name:"full-selected") }
        await MainActor.run { m.beginFileDrop(count:urls.count);XCTAssertTrue(m.acceptFileDrop(urls)) }
        try await waitForWork(m)
        await MainActor.run { m.surfaceSize=m.targetSize;c.applyWindowLayout();m.selectAllShelfFiles();XCTAssertEqual(m.selection.ids.count,5) }
        try await Task.sleep(for:.milliseconds(150))
        try await MainActor.run { try capture(c,name:"mini-selected") }
        await MainActor.run { m.beginFileDrop(count:2);XCTAssertTrue(m.acceptFileDrop([urls[0],root.appendingPathComponent("Недоступный файл.txt")])) }
        try await waitForWork(m)
        await MainActor.run { m.selectAllShelfFiles();XCTAssertEqual(m.selection.ids.count,1) }
        try await Task.sleep(for:.milliseconds(150))
        try await MainActor.run { try capture(c,name:"mini-selected-error") }
    }
    @MainActor private func descendants(_ view:NSView)->[NSView] { view.subviews.flatMap{[$0]+descendants($0)} }
    @MainActor private func capture(_ c:NotchWindowController,name:String) throws {
        let host=try XCTUnwrap(c.panel.contentView?.subviews.first)
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep)
        let out=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/0.5.2/\(name).png")
        try FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true)
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:out)
    }
}
