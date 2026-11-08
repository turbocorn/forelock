import XCTest
import AppKit
import SwiftUI
import QuickLookUI
import ChelkaCore
@testable import Chelka

final class MiniShelfTests: XCTestCase {
    func testExitDelayHasNoFixedLifetimeAndInteractionCancelsDeadline() {
        var p = MiniShelfPointerPolicy(); let id = UUID()
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:0,inside:true,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:100,inside:true,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:101,inside:false,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:101.7,inside:false,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:101.75,inside:true,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:102,inside:false,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:200,inside:false,interacting:true))
        XCTAssertFalse(p.shouldDismiss(presentation:id,now:201,inside:false,interacting:false))
        XCTAssertTrue(p.shouldDismiss(presentation:id,now:201.9,inside:false,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:UUID(),now:202,inside:false,interacting:false))
        XCTAssertFalse(p.shouldDismiss(presentation:nil,now:300,inside:false,interacting:false))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Forelock-mini-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    @MainActor private func model(_ root: URL) -> NotchModel {
        let domain = "dev.forelock.mini-test.\(UUID())"
        let defaults = UserDefaults(suiteName:domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName:domain) }
        return NotchModel(shelf:ShelfModel(root:root.appendingPathComponent("Shelf")),preferences:Preferences(defaults:defaults))
    }
    private func files(_ root: URL, count: Int) throws -> [URL] {
        try (1...count).map { n in
            let url = root.appendingPathComponent("Файл \(n).txt")
            try Data("Forelock mini shelf fixture \(n)\n".utf8).write(to:url)
            return url
        }
    }
    private func drop(_ urls: [URL], into model: NotchModel) async throws {
        await MainActor.run { model.beginFileDrop(count:urls.count); XCTAssertTrue(model.acceptFileDrop(urls)) }
        let deadline = Date().addingTimeInterval(5)
        while await MainActor.run(body:{model.isInteracting}) && Date()<deadline { try await Task.sleep(for:.milliseconds(20)) }
        await MainActor.run { XCTAssertEqual(model.state,.miniShelf); XCTAssertFalse(model.magnetic) }
    }

    func testOnlyLatestActualImportedItemsAppearAndOverflowDoesNotCopyAgain() async throws {
        let root = try fixture(), sources = try files(root,count:5)
        let m = await MainActor.run { model(root) }
        try await drop(Array(sources.prefix(4)),into:m)
        await MainActor.run { XCTAssertEqual(m.miniShelfItems.count,4); XCTAssertEqual(m.miniShelfOverflow,0) }
        try await drop(sources,into:m)
        await MainActor.run {
            XCTAssertEqual(m.recentItems.map(\.name),sources.map(\.lastPathComponent))
            XCTAssertEqual(m.miniShelfItems.count,3); XCTAssertEqual(m.miniShelfOverflow,2)
            XCTAssertEqual(m.shelf.items.count,9)
        }
        try await drop([sources[0]],into:m)
        await MainActor.run {
            XCTAssertEqual(m.recentItems.count,1); XCTAssertEqual(m.miniShelfOverflow,0)
            XCTAssertEqual(m.shelf.items.count,10)
            m.dismissMiniShelf(); XCTAssertEqual(m.state,.idle)
        }
    }

    func testPartialSuccessKeepsErrorsAndQuickLookReturnsToSameRecentItems() async throws {
        let root=try fixture(), sources=try files(root,count:2)
        let m=await MainActor.run { () -> NotchModel in let m=model(root);m.open(.shelf);return m }
        try await drop([sources[0],root.appendingPathComponent("Нет такого файла.txt"),sources[1]],into:m)
        await MainActor.run {
            XCTAssertEqual(m.recentDrop?.attempted,3);XCTAssertEqual(m.recentItems.count,2)
            XCTAssertTrue(m.recentDrop?.error?.contains("Нет такого файла") == true)
            let ids=m.recentDrop!.itemIDs
            let item=m.recentItems[0]
            XCTAssertNotEqual(m.shelf.url(for:item),sources[0]);XCTAssertTrue(FileManager.default.fileExists(atPath:m.shelf.url(for:item).path))
            m.openRecentFile(item.id);XCTAssertEqual(m.state,.preview(item.id));XCTAssertTrue(m.previewReturnsToMiniShelf)
            m.backFromPreview();XCTAssertEqual(m.state,.miniShelf);XCTAssertEqual(m.recentDrop?.itemIDs,ids)
            m.openRecentFile(item.id);XCTAssertTrue(m.close(reason:"escape"));XCTAssertEqual(m.state,.miniShelf)
            m.dismissMiniShelf();XCTAssertEqual(m.state,.shelf)
        }
        for url in sources { XCTAssertTrue(FileManager.default.fileExists(atPath:url.path)) }
    }

    func testMiniShelfRetainsDuringDragOutAndFullShelfStaysPinned() async throws {
        let root=try fixture(), sources=try files(root,count:1)
        let pair=try await MainActor.run { () -> (NotchModel,NotchWindowController) in
            _=NSApplication.shared
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("WindowServer unavailable") }
            let m=model(root);let c=NotchWindowController(model:m);m.open(.shelf);return(m,c)
        }
        let (m,c)=pair
        try await drop(sources,into:m)
        await MainActor.run {
            defer { c.stop() }
            let g=m.geometry!;m.surfaceSize=m.targetSize;c.applyWindowLayout()
            let inside=CGPoint(x:g.anchor.x,y:g.anchor.y-100),outside=CGPoint(x:g.anchor.x,y:g.anchor.y-500)
            c.samplePointer(at:inside,now:10,pressed:false);c.samplePointer(at:inside,now:100,pressed:false)
            XCTAssertEqual(m.state,.miniShelf)
            m.draggingOut=true;c.samplePointer(at:outside,now:110,pressed:true);c.samplePointer(at:outside,now:150,pressed:false)
            XCTAssertEqual(m.state,.miniShelf)
            m.draggingOut=false;c.samplePointer(at:outside,now:151,pressed:false)
            c.samplePointer(at:outside,now:151.7,pressed:false);XCTAssertEqual(m.state,.miniShelf)
            c.samplePointer(at:inside,now:151.75,pressed:false)
            c.samplePointer(at:outside,now:152,pressed:false);c.samplePointer(at:outside,now:152.9,pressed:false)
            XCTAssertEqual(m.state,.shelf)
            m.open(.shelf,reason:"recent-all-files")
            c.samplePointer(at:outside,now:200,pressed:false);c.samplePointer(at:outside,now:500,pressed:false)
            XCTAssertEqual(m.state,.shelf)
        }
    }

    func testNativeResultRendersAndUsesExistingQuickLookWithSavedCopy() async throws {
        let root=try fixture(), sources=try files(root,count:5)
        let pair=try await MainActor.run { () -> (NotchModel,NotchWindowController) in
            _=NSApplication.shared
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("WindowServer unavailable") }
            let m=model(root);let c=NotchWindowController(model:m);m.open(.shelf);return(m,c)
        }
        let(m,c)=pair
        addTeardownBlock { await MainActor.run { c.stop() } }
        try await drop(sources,into:m)
        try await MainActor.run {
            m.surfaceSize=m.targetSize;c.applyWindowLayout()
            try capture(c,name:"mini-overflow")
            let nativeTiles=descendants(c.panel.contentView!).compactMap{$0 as? DraggableFileView}
            XCTAssertEqual(nativeTiles.count,3)
            XCTAssertEqual(Set(nativeTiles.compactMap(\.fileURL)),Set(m.miniShelfItems.map{m.shelf.url(for:$0)}))
            m.openRecentFile(m.recentItems[0].id);m.surfaceSize=m.targetSize;c.applyWindowLayout()
        }
        try await Task.sleep(for:.milliseconds(150))
        try await MainActor.run {
            c.panel.contentView?.layoutSubtreeIfNeeded()
            try capture(c,name:"quick-look")
            let preview=try XCTUnwrap(descendants(c.panel.contentView!).compactMap{$0 as? QLPreviewView}.first)
            XCTAssertEqual(preview.previewItem?.previewItemURL,m.shelf.url(for:m.recentItems[0]))
            m.backFromPreview();XCTAssertEqual(m.state,.miniShelf)
        }
        try await drop([sources[0],root.appendingPathComponent("Недоступный файл.txt")],into:m)
        try await Task.sleep(for:.milliseconds(150))
        try await MainActor.run {
            m.surfaceSize=m.targetSize;c.applyWindowLayout();try capture(c,name:"mini-partial")
            m.open(.shelf);XCTAssertNil(m.recentDrop)
            m.surfaceSize=m.targetSize;c.applyWindowLayout();try capture(c,name:"all-files")
        }
    }
    @MainActor private func descendants(_ view:NSView)->[NSView] { view.subviews.flatMap{[$0]+descendants($0)} }
    @MainActor private func capture(_ c:NotchWindowController,name:String) throws {
        let host=try XCTUnwrap(c.panel.contentView?.subviews.first)
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        let output=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/0.5.1/\(name).png")
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output)
    }
}
