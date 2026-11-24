//  `BlurHash.image`: the placeholder painted while artwork is in flight.
//
//  The hashes here are worked out by hand from the format: one base-83
//  character for the component counts, one for the AC scale, four for the
//  DC colour (an sRGB triple), then two per AC component. A hash with one
//  component is a flat colour, which makes its pixels checkable exactly.

import CoreGraphics
import XCTest
@testable import Aquarium

final class CoreBlurHashTests: XCTestCase {
    /// The image's bytes, four to a pixel: red, green, blue, unused.
    private func bytes(_ image: CGImage) -> [UInt8] {
        guard let stored = image.dataProvider?.data else { return [] }
        return [UInt8](stored as Data)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let all = bytes(image)
        let o = y * image.bytesPerRow + x * 4
        guard o + 2 < all.count else { return [] }
        return [all[o], all[o + 1], all[o + 2]]
    }

    func testAOneComponentHashIsAFlatColour() throws {
        // 0xFFFFFF, 0xFF0000 and 0x0000FF in base 83.
        let cases: [(hash: String, colour: [UInt8])] = [
            ("00TSUA", [255, 255, 255]),
            ("00TI:j", [255, 0, 0]),
            ("000036", [0, 0, 255]),
            ("000000", [0, 0, 0]),
        ]
        for (hash, colour) in cases {
            let image = try XCTUnwrap(BlurHash.image(from: hash, width: 4, height: 4), hash)
            XCTAssertEqual(pixel(image, x: 0, y: 0), colour, hash)
            XCTAssertEqual(pixel(image, x: 3, y: 3), colour, "\(hash): every pixel is the same colour")
            XCTAssertEqual(pixel(image, x: 2, y: 1), colour, hash)
        }
    }

    func testTheImageIsTheSizeAskedFor() throws {
        let image = try XCTUnwrap(BlurHash.image(from: "00TSUA", width: 8, height: 5))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 5)
        XCTAssertEqual(bytes(image).count, 8 * 5 * 4)
        let standard = try XCTUnwrap(BlurHash.image(from: "00TSUA"))
        XCTAssertEqual(standard.width, 32)
        XCTAssertEqual(standard.height, 32)
    }

    /// A real hash, four components across and three down: 4 + 2 × 12
    /// characters. It is a picture, not a flat colour.
    func testAFullHashDecodesToAPicture() throws {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        XCTAssertEqual(hash.count, 28)
        let image = try XCTUnwrap(BlurHash.image(from: hash, width: 16, height: 16))
        var colours = Set<[UInt8]>()
        for y in 0..<16 {
            for x in 0..<16 { colours.insert(pixel(image, x: x, y: y)) }
        }
        XCTAssertGreaterThan(colours.count, 1, "the AC components vary the colour across the image")
    }

    func testAMalformedHashIsNoImage() {
        XCTAssertNil(BlurHash.image(from: ""))
        XCTAssertNil(BlurHash.image(from: "00TSU"), "shorter than the header and the DC colour")
        // "L" says 4 × 3 components, which needs 28 characters.
        XCTAssertNil(BlurHash.image(from: "L00000"))
        XCTAssertNil(BlurHash.image(from: "LEHV6nWB2yk8pyo0adR*.7kCMdn"), "one character short")
        XCTAssertNil(BlurHash.image(from: "00TSUA00"), "longer than its component count allows")
    }

    /// `Artwork.hash` hands over a hash only when it is long enough to be one.
    func testArtworkHandsOverOnlyAHashFiledUnderTheSameTag() throws {
        let item = try JSONDecoder().decode(BaseItem.self, from: Data("""
        {"Id":"a","Type":"Movie","ImageTags":{"Primary":"p1"},"BackdropImageTags":["b1"],
         "ImageBlurHashes":{"Primary":{"p1":"00TSUA","other":"00TI:j"},"Backdrop":{"b1":"short"}}}
        """.utf8))
        XCTAssertEqual(Artwork.hash(item), "00TSUA")
        XCTAssertNil(Artwork.hash(item, type: "Backdrop"), "five characters is not a hash")
        XCTAssertNil(Artwork.hash(item, type: "Logo"), "no Logo tag, so no hash")
    }
}
