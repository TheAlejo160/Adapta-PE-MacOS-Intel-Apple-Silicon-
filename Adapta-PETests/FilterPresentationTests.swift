import XCTest
import AppKit
import CoreGraphics
@testable import Adapta_PE

final class FilterPresentationTests: XCTestCase {
    @MainActor func testFirstImageAndCancellation() {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        var firstImages = 0
        let output = FilterOutput(frame: CGRect(x: -10000, y: -10000, width: 4, height: 4), matrix: ColorFilter.ninguno.matrix, onError: {}) { firstImages += 1 }
        XCTAssertFalse(output.window.isVisible)
        output.present(image)
        XCTAssertTrue(output.window.isVisible)
        XCTAssertEqual(firstImages, 1)
        output.present(image)
        XCTAssertEqual(firstImages, 1)
        output.invalidate()
        output.present(image)
        XCTAssertFalse(output.window.isVisible)
        XCTAssertEqual(firstImages, 1)
    }
}
