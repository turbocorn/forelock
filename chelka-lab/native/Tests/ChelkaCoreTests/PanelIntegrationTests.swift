import XCTest
import AppKit
import SwiftUI
import ChelkaCore
@testable import Chelka

final class PanelIntegrationTests: XCTestCase {
    /// This is an AppKit/WindowServer integration check, not a geometry unit test.
    /// The screenshot review remains a separate required acceptance step.
    func testActualPanelAndHostingViewReachDisplayTop() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("WindowServer is unavailable; cannot verify real panel placement") }
            let domain = "dev.chelka.geometry-test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
            let model = NotchModel(shelf: ShelfModel(root: temp), preferences: Preferences(defaults: defaults))
            let controller = NotchWindowController(model: model)
            defer { controller.stop(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: temp) }
            let geometry = try XCTUnwrap(model.geometry)
            let panel = controller.panel
            let container = try XCTUnwrap(panel.contentView)
            let host = try XCTUnwrap(container.subviews.first as? NSHostingView<NotchRootView>)
            XCTAssertTrue(host.safeAreaRegions.isEmpty)
            XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.statusBar.rawValue)
            XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
            var measurements: [[String: Any]] = []
            for (state, destination) in [("Idle", NotchState.idle), ("Hover", NotchState.hover), ("Expanded", NotchState.overview)] {
                if destination == .idle { model.close() } else { model.open(destination) }
                let size = model.targetSize
                model.surfaceSize = size
                let requested = geometry.frame(for: size)
                panel.setFrame(requested, display: true)
                container.layoutSubtreeIfNeeded()
                XCTAssertEqual(panel.frame.maxY, geometry.anchor.y, accuracy: 0.5, "Actual AppKit window was constrained below the display")
                XCTAssertEqual(panel.frame.midX, geometry.anchor.x, accuracy: 0.5)
                XCTAssertEqual(host.bounds.width, size.width, accuracy: 0.5)
                XCTAssertEqual(host.bounds.height, size.height, accuracy: 0.5)
                let header = geometry.headerLayout(for: size)
                let camera = geometry.cameraRegion(for: size)
                if geometry.hasNotch {
                    XCTAssertLessThanOrEqual(header.left.maxX, camera.minX)
                    XCTAssertGreaterThanOrEqual(header.right.minX, camera.maxX)
                } else {
                    XCTAssertTrue(camera.isNull)
                    XCTAssertEqual(header.left.maxX, header.right.minX)
                }
                measurements.append(["headerLeft": NSStringFromRect(header.left), "headerRight": NSStringFromRect(header.right),
                                     "cameraExcluded": NSStringFromRect(camera), "state": state, "requestedFrame": NSStringFromRect(requested), "actualFrame": NSStringFromRect(panel.frame),
                                     "hostBounds": NSStringFromRect(host.bounds), "hostSafeAreaDisabled": host.safeAreaRegions.isEmpty,
                                     "anchorTop": geometry.anchor.y, "windowTop": panel.frame.maxY])
            }
            let report: [String: Any] = ["screenFrame": NSStringFromRect(geometry.screenFrame), "neckWidth": geometry.neckWidth,
                                         "neckHeight": geometry.neckHeight, "menuBarHeight": geometry.menuBarHeight, "headerHeight": geometry.headerHeight, "windowLevel": panel.level.rawValue,
                                         "statusBarLevel": NSWindow.Level.statusBar.rawValue, "measurements": measurements]
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("artifacts/0.4/window-audit.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }
    }

    /// Exercises production routing on a real panel with injected positions.
    /// These are deterministic regression inputs, not a manual cursor test.
    func testTwentyCyclesOfHoverRetentionAndPinnedExpanded() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("WindowServer is unavailable") }
            let domain = "dev.chelka.pointer-test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
            let model = NotchModel(shelf: ShelfModel(root: temp), preferences: Preferences(defaults: defaults))
            let controller = NotchWindowController(model: model)
            defer { controller.stop(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: temp) }
            let geometry = try XCTUnwrap(model.geometry)
            let camera = CGPoint(x: geometry.anchor.x, y: geometry.anchor.y - 15)
            let outside = CGPoint(x: geometry.anchor.x, y: geometry.anchor.y - 400)
            var now = 1.0
            for cycle in 0..<20 {
                controller.samplePointer(at: outside, now: now, pressed: false)
                controller.samplePointer(at: camera, now: now + 0.1, pressed: false)
                controller.samplePointer(at: camera, now: now + 1, pressed: false)
                XCTAssertEqual(model.state, .hover, "cycle \(cycle)")
                controller.samplePointer(at: camera, now: now + 6, pressed: false)
                XCTAssertEqual(model.state, .hover)
                let hoverFrame = geometry.frame(for: model.targetSize)
                controller.panel.setFrame(hoverFrame, display: true)
                let button = CGPoint(x: hoverFrame.midX + 150, y: hoverFrame.maxY - 80)
                controller.samplePointer(at: button, now: now + 7, pressed: false)
                controller.samplePointer(at: button, now: now + 8, pressed: false)
                XCTAssertEqual(model.state, .hover)
                model.open(.overview)
                controller.samplePointer(at: outside, now: now + 9, pressed: false)
                controller.samplePointer(at: outside, now: now + 15, pressed: false)
                XCTAssertEqual(model.state, .overview)
                controller.mouseDown(at: outside)
                XCTAssertEqual(model.state, .idle)
                // A still-wide closing frame must not become an Idle trigger.
                controller.panel.setFrame(geometry.frame(for: CGSize(width: 900, height: 250)), display: true)
                let browserTab = CGPoint(x: camera.x, y: geometry.anchor.y - 70)
                controller.samplePointer(at: browserTab, now: now + 16, pressed: true)
                controller.samplePointer(at: browserTab, now: now + 18, pressed: false)
                XCTAssertEqual(model.state, .idle)
                XCTAssertFalse(model.magnetic)
                now += 20
            }
            let entries = try Data(contentsOf: controller.diagnostics.url).split(separator: 10)
            XCTAssertTrue(entries.contains { (try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["reason"] as? String == "hover-dwell" })
        }
    }
}
