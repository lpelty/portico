import XCTest
@testable import Portico

/// v0.14 (§6b.3): a brighter acting glow. The line stays 3 pt at full
/// accent; the glow is stronger and its pulse never falls below 75%.
final class ActingGlowTests: XCTestCase {
    func testTheLineStaysThreePoints() {
        XCTAssertEqual(ViewerActingGlow.lineWidth, 3)
    }

    func testThePulseFloorIsSeventyFivePercent() {
        XCTAssertEqual(ViewerActingGlow.dimOpacity, 0.75, "75-100%, was 55-100%")
    }

    func testTheGlowIsStrongerThanV013() {
        // v0.13: a 10 pt band at 45% accent, blurred 8.
        XCTAssertGreaterThan(ViewerActingGlow.glowOpacity, 0.45)
        XCTAssertGreaterThan(ViewerActingGlow.glowWidth, 10)
        XCTAssertGreaterThan(ViewerActingGlow.glowBlur, 8)
        XCTAssertLessThanOrEqual(ViewerActingGlow.glowOpacity, 1)
    }
}
