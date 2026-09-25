// HUDScaleTests -- the window-mode panels' screen-relative size factor.
//
// Tests the pure size -> factor rule rather than `factor(for: NSScreen)`: the
// NSScreen overload only reads `frame.size` and forwards it here, and the
// machine running the suite has whatever displays it has.

import XCTest
@testable import HammerdeckKit

final class HUDScaleTests: XCTestCase {
    func testFactorScalesWithScreenHeightFlooredAtOne() {
        XCTAssertEqual(HUDScale.factor(forSize: CGSize(width: 1000, height: 600)), 1.0, accuracy: 1e-9,
                       "a 600pt-tall screen is the base size exactly")
        XCTAssertEqual(HUDScale.factor(forSize: CGSize(width: 800, height: 500)), 1.0, accuracy: 1e-9,
                       "a shorter screen never shrinks a panel below the base size")
        XCTAssertEqual(HUDScale.factor(forSize: CGSize(width: 1440, height: 900)), 1.5, accuracy: 1e-9)
        XCTAssertEqual(HUDScale.factor(forSize: CGSize(width: 1920, height: 1080)), 1.8, accuracy: 1e-9)
        XCTAssertEqual(HUDScale.factor(forSize: CGSize(width: 2560, height: 1440)), 2.4, accuracy: 1e-9)
    }

    func testUltrawideWidthDoesNotInflateTheFactor() {
        XCTAssertEqual(HUDScale.factor(forSize: CGSize(width: 5120, height: 1440)),
                       HUDScale.factor(forSize: CGSize(width: 2560, height: 1440)), accuracy: 1e-9)
    }

    /// A portrait display's height would size a panel wider than the display
    /// itself (1920 tall is 3.2x, a ~530pt Deck card becomes ~1700pt on a
    /// 1080pt-wide screen), so the width bounds it there.
    func testPortraitDisplayIsBoundedByItsWidth() {
        XCTAssertEqual(HUDScale.factor(forSize: CGSize(width: 1080, height: 1920)), 1.8, accuracy: 1e-9)
    }
}
