import CoreGraphics
import XCTest
@testable import ChelkaCore

final class InteractionTests: XCTestCase {
    private let g = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                  visibleFrame: CGRect(x: 0, y: 59, width: 1800, height: 1066), safeTop: 38,
                                  leftArea: CGRect(x: 0, y: 1131, width: 790, height: 38),
                                  rightArea: CGRect(x: 1010, y: 1131, width: 790, height: 38))

    func testCameraRetainsHoverThroughoutOpeningAndFiveSecondsAtRest() {
        var policy = NotchPointerPolicy()
        let pointer = CGPoint(x: 900, y: 1150)
        for (index, width) in [220.0, 260, 350, 420, 420, 420].enumerated() {
            let region = NotchPointerRegions(geometry: g, frame: g.frame(for: CGSize(width: width, height: 140)), pointer: pointer)
            XCTAssertTrue(region.inActivation)
            XCTAssertFalse(region.inControls) // No camera controls, but keep the panel.
            XCTAssertTrue(region.retainsHover)
            XCTAssertNil(policy.sample(mode: .hover, now: Double(index), inActivation: region.inActivation, retainsHover: region.retainsHover,
                                       pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
            XCTAssertNil(policy.outsideSince)
        }
    }

    func testExactUpperDisplayEdgeBelongsToCameraWithoutGrowingTheZone() {
        let frame = g.frame(for: g.idleSize)
        for x in [790.0, 900, 1009.999] {
            XCTAssertTrue(NotchPointerRegions(geometry: g, frame: frame, pointer: CGPoint(x: x, y: 1169)).inActivation)
        }
        for point in [CGPoint(x: 789.999, y: 1169), CGPoint(x: 1010, y: 1169), CGPoint(x: 900, y: 1130.999)] {
            XCTAssertFalse(NotchPointerRegions(geometry: g, frame: frame, pointer: point).inActivation)
        }
    }

    func testExitDeadlineIsSixHundredMillisecondsAndReturnCancelsIt() {
        var policy = NotchPointerPolicy()
        func sample(_ now: Double, _ inside: Bool) -> NotchPointerAction? {
            policy.sample(mode: .hover, now: now, inActivation: false, retainsHover: inside, pressed: false,
                          suspended: false, hoverEnabled: true, hoverDelay: 0.32)
        }
        XCTAssertNil(sample(1, false))
        XCTAssertNil(sample(1.55, true))
        XCTAssertNil(policy.outsideSince)
        XCTAssertNil(sample(2, false))
        XCTAssertNil(sample(2.59, false))
        XCTAssertEqual(sample(2.61, false), .closeHover)
    }

    func testExpandedHasNoHoverCloseDeadline() {
        var policy = NotchPointerPolicy()
        for now in stride(from: 0.0, through: 20, by: 0.1) {
            XCTAssertNil(policy.sample(mode: .expanded, now: now, inActivation: false, retainsHover: false,
                                       pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
            XCTAssertNil(policy.outsideSince)
        }
    }

    func testIdleCannotActivateFromBrowserOrPreviousExpandedFrame() {
        var policy = NotchPointerPolicy()
        for cycle in 0..<20 {
            for (index, point) in [CGPoint(x: 900, y: 1099), CGPoint(x: 785, y: 1150), CGPoint(x: 1015, y: 1150), CGPoint(x: 900, y: 1130)].enumerated() {
                let region = NotchPointerRegions(geometry: g, frame: g.frame(for: CGSize(width: 900, height: 250)), pointer: point)
                XCTAssertFalse(region.inActivation)
                XCTAssertFalse(region.acceptsMouse(in: .idle))
                XCTAssertNil(policy.sample(mode: .idle, now: Double(cycle * 10 + index), inActivation: region.inActivation,
                                           retainsHover: region.retainsHover, pressed: index.isMultiple(of: 2), suspended: false,
                                           hoverEnabled: true, hoverDelay: 0.32))
            }
        }
    }

    func testDismissalRequiresExitBeforeHoverCanReopen() {
        var policy = NotchPointerPolicy()
        policy.transitioned(to: .idle)
        XCTAssertNil(policy.sample(mode: .idle, now: 1, inActivation: true, retainsHover: true, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
        XCTAssertNil(policy.sample(mode: .idle, now: 10, inActivation: true, retainsHover: true, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
        XCTAssertNil(policy.sample(mode: .idle, now: 11, inActivation: false, retainsHover: false, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
        XCTAssertNil(policy.sample(mode: .idle, now: 12, inActivation: true, retainsHover: true, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
        XCTAssertEqual(policy.sample(mode: .idle, now: 12.33, inActivation: true, retainsHover: true, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32), .openHover)
    }

    func testModalAndRealDragSuspendDeadlinesWithoutAccumulatingTime() {
        var policy = NotchPointerPolicy()
        XCTAssertNil(policy.sample(mode: .hover, now: 0, inActivation: false, retainsHover: false, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
        XCTAssertNil(policy.sample(mode: .hover, now: 10, inActivation: false, retainsHover: false, pressed: false, suspended: true, hoverEnabled: true, hoverDelay: 0.32))
        XCTAssertNil(policy.outsideSince)
        XCTAssertNil(policy.sample(mode: .hover, now: 11, inActivation: false, retainsHover: false, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
        XCTAssertNil(policy.sample(mode: .hover, now: 11.59, inActivation: false, retainsHover: false, pressed: false, suspended: false, hoverEnabled: true, hoverDelay: 0.32))
    }
}
