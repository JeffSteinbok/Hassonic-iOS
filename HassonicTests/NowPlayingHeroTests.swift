import SwiftUI
import XCTest
@testable import Hassonic

/// The Now Playing card is a square the cover fills, capped on iPad, with the
/// gradient only behind the text at the bottom.
@MainActor
final class NowPlayingHeroTests: XCTestCase {

    private func render(width: CGFloat, showsScrim: Bool = true) -> CGImage? {
        let card = NowPlayingHeroSquare(showsScrim: showsScrim) {
            Color.white
        } overlay: {
            Color.clear.frame(height: 100)
        }
        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Red, green, blue at a point, 0...255.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    func testCardIsSquareAtPhoneWidth() throws {
        let image = try XCTUnwrap(render(width: 370))
        XCTAssertEqual(image.width, 370)
        XCTAssertEqual(image.height, 370)
    }

    func testCardStopsAtMaxSideOnIPad() throws {
        let image = try XCTUnwrap(render(width: 900))
        XCTAssertEqual(image.width, Int(NowPlayingHero.maxSide))
        XCTAssertEqual(image.height, Int(NowPlayingHero.maxSide))
    }

    func testCoverIsNotDarkenedAboveTheText() throws {
        let image = try XCTUnwrap(render(width: 370))
        // Above the text plus the gradient's lead-in: the cover as it is.
        let top = pixel(image, x: 185, y: 60)
        XCTAssertEqual(top.0, 255)
        XCTAssertEqual(top.1, 255)
        XCTAssertEqual(top.2, 255)
        // Middle-left edge: the art reaches the side, no strip or bar.
        let side = pixel(image, x: 1, y: 150)
        XCTAssertEqual(side.0, 255)
    }

    func testTextSitsOnAGradientAtTheBottom() throws {
        let image = try XCTUnwrap(render(width: 370))
        let bottom = pixel(image, x: 185, y: 360)
        XCTAssertLessThan(bottom.0, 100, "white art should be well darkened behind the controls")
    }

    func testNoGradientWithoutMedia() throws {
        let image = try XCTUnwrap(render(width: 370, showsScrim: false))
        XCTAssertEqual(pixel(image, x: 185, y: 360).0, 255)
    }
}
