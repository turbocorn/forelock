import CoreGraphics
import XCTest
@testable import ChelkaCore

final class CoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chelka-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCopiesSurviveNewRepositoryAndRemovalPreservesOriginal() async throws {
        let temp = try temporaryDirectory()
        let source = temp.appendingPathComponent("Заметка.txt")
        let contents = Data("Проверка настоящей копии".utf8)
        try contents.write(to: source)
        let root = temp.appendingPathComponent("storage")
        let first = ShelfRepository(root: root)
        let item = try await first.importFile(at: source)
        XCTAssertEqual(try Data(contentsOf: first.fileURL(for: item)), contents)
        // Source edits after the drop do not change the shelf copy.
        try Data("Изменённый оригинал".utf8).write(to: source)
        let second = ShelfRepository(root: root)
        let restored = try await second.load()
        XCTAssertEqual(restored, [item])
        XCTAssertEqual(try Data(contentsOf: second.fileURL(for: item)), contents)
        try await second.remove(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.fileURL(for: item).path))
        let remaining = try await second.load()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSameNamesHaveIndependentCopies() async throws {
        let temp = try temporaryDirectory()
        let source = temp.appendingPathComponent("same.txt")
        try Data("one".utf8).write(to: source)
        let store = ShelfRepository(root: temp.appendingPathComponent("storage"))
        let a = try await store.importFile(at: source)
        try Data("two".utf8).write(to: source)
        let b = try await store.importFile(at: source)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(try String(contentsOf: store.fileURL(for: a), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: store.fileURL(for: b), encoding: .utf8), "two")
        let items = try await store.load()
        XCTAssertEqual(items.count, 2)
    }

    func testCorruptIndexIsNotOverwritten() async throws {
        let temp = try temporaryDirectory()
        let root = temp.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("not JSON".utf8)
        try data.write(to: root.appendingPathComponent("shelf.json"))
        let source = temp.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: source)
        let store = ShelfRepository(root: root)
        do { _ = try await store.importFile(at: source); XCTFail("Must report index corruption") }
        catch { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("shelf.json")), data) }
    }

    func testNotchGeometryUsesPointsAndKeepsUpperAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let g = NotchGeometry(screenFrame: screen, visibleFrame: screen.insetBy(dx: 0, dy: 38), safeTop: 38,
                              leftArea: CGRect(x: 0, y: 1131, width: 790, height: 38), rightArea: CGRect(x: 1010, y: 1131, width: 790, height: 38))
        XCTAssertTrue(g.hasNotch)
        XCTAssertEqual(g.neckWidth, 220)
        XCTAssertEqual(g.idleSize, CGSize(width: 220, height: 38))
        XCTAssertEqual(g.hoverWidth, 420)
        XCTAssertEqual(g.expandedWidth, 900)
        for size in [g.idleSize, CGSize(width: 350, height: 204), CGSize(width: 400, height: 284)] {
            XCTAssertEqual(g.frame(for: size).maxY, 1169)
            XCTAssertEqual(g.frame(for: size).midX, 900)
        }
        let external = NotchGeometry(screenFrame: CGRect(x: 1800, y: -200, width: 1920, height: 1080), visibleFrame: CGRect(x: 1800, y: -200, width: 1920, height: 1056), safeTop: 0, leftArea: nil, rightArea: nil)
        XCTAssertFalse(external.hasNotch)
        XCTAssertEqual(external.anchor.y, 880)
        XCTAssertEqual(external.anchor.x, 2760)
        XCTAssertEqual(external.idleSize, CGSize(width: 120, height: 24))
        XCTAssertTrue(external.cameraRegion(for: external.idleSize).isNull)
    }

    func testSpringInterruptsWithoutJumpingAndConverges() {
        var spring = SurfaceSpring(CGSize(width: 236, height: 46))
        let large = CGSize(width: 400, height: 284)
        let compact = CGSize(width: 236, height: 46)
        for _ in 0..<10 { _ = spring.step(toward: large, dt: 1.0 / 60) }
        let prior = spring.value
        _ = spring.step(toward: compact, dt: 1.0 / 60)
        XCTAssertLessThan(abs(spring.value.height - prior.height), 40)
        for _ in 0..<240 { _ = spring.step(toward: compact, dt: 1.0 / 60) }
        XCTAssertEqual(spring.value, compact)
        XCTAssertEqual(spring.velocity, .zero)
    }
}


extension CoreTests {
    func testFullWidthTopAndCameraExclusionDuringExpansion() {
        let g = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                              visibleFrame: CGRect(x: 0, y: 59, width: 1800, height: 1066), safeTop: 38,
                              leftArea: CGRect(x: 0, y: 1131, width: 790, height: 38),
                              rightArea: CGRect(x: 1010, y: 1131, width: 790, height: 38))
        XCTAssertEqual(g.menuBarHeight, 44)
        XCTAssertEqual(g.headerHeight, 38) // Hardware controls content; menu does not offset it.
        for width in stride(from: CGFloat(420), through: 900, by: 20) {
            let size = CGSize(width: width, height: 250)
            let path = g.outline(for: size)
            let header = g.headerLayout(for: size)
            let camera = g.cameraRegion(for: size)
            XCTAssertTrue(path.contains(CGPoint(x: 1, y: 1)))
            XCTAssertTrue(path.contains(CGPoint(x: width - 1, y: 1)))
            XCTAssertTrue(g.containsInteractivePoint(CGPoint(x: 10, y: 19), in: size))
            XCTAssertFalse(g.containsInteractivePoint(CGPoint(x: width / 2, y: 19), in: size))
            XCTAssertFalse(g.containsInteractivePoint(CGPoint(x: -1, y: 19), in: size))
            XCTAssertLessThanOrEqual(header.left.maxX, camera.minX)
            XCTAssertGreaterThanOrEqual(header.right.minX, camera.maxX)
            XCTAssertEqual(header.left.minY, 0)
            XCTAssertEqual(header.right.minY, 0)
            XCTAssertEqual(header.camera.midX, width / 2)
            XCTAssertEqual(path.boundingBox, CGRect(origin: .zero, size: size))
            XCTAssertEqual(g.frame(for: size).maxY, 1169)
        }
    }
}
