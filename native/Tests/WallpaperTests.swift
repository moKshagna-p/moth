import AppKit
import XCTest
@testable import MothNative

final class WallpaperTests: XCTestCase {
    func testWideWallpaperCoversWindowAndCentersCrop() {
        let frame = wallpaperFrame(image: CGSize(width: 2000, height: 1000),
                                   window: CGSize(width: 1000, height: 1000),
                                   focusX: 50, focusY: 50)
        XCTAssertEqual(frame, CGRect(x: -500, y: 0, width: 2000, height: 1000))
    }

    func testTallWallpaperFocusSelectsTopAndBottom() {
        let image = CGSize(width: 1000, height: 2000)
        let window = CGSize(width: 1000, height: 1000)
        XCTAssertEqual(wallpaperFrame(image: image, window: window, focusX: 50, focusY: 0).minY, 0)
        XCTAssertEqual(wallpaperFrame(image: image, window: window, focusX: 50, focusY: 100).minY, -1000)
    }

    func testCropClampsOutOfRangeFocus() {
        let frame = wallpaperFrame(image: CGSize(width: 2000, height: 1000),
                                   window: CGSize(width: 1000, height: 1000),
                                   focusX: 150, focusY: -50)
        XCTAssertEqual(frame, CGRect(x: -1000, y: 0, width: 2000, height: 1000))
    }

    func testLuminanceUsesLinearSRGB() {
        XCTAssertEqual(relativeLuminance(0, 0, 0), 0)
        XCTAssertEqual(relativeLuminance(1, 1, 1), 1, accuracy: 0.000001)
        XCTAssertEqual(relativeLuminance(0.5, 0.5, 0.5), 0.214041, accuracy: 0.000001)
        XCTAssertEqual(relativeLuminance(1, 0, 0), 0.2126, accuracy: 0.000001)
    }
}
