//  BlurHash decoding — the placeholder painted while artwork is in flight.
//
//  A port of blurhash.ts. The hash is a couple of dozen base-83 characters
//  carried on the item itself, so the shape and colour of a poster can be drawn
//  before a single byte of the picture has arrived. Decoded at a tiny size (the
//  result is blurred by definition) and then scaled up by the view.

import CoreGraphics
import Foundation

enum BlurHash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    private static func decode83(_ s: Substring) -> Int {
        var value = 0
        for c in s {
            guard let i = alphabet.firstIndex(of: c) else { return 0 }
            value = value * 83 + i
        }
        return value
    }

    private static func sRGBToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> UInt8 {
        let v = max(0, min(1, value))
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255 + 0.5))))
    }

    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        (value < 0 ? -1 : 1) * powf(abs(value), exp)
    }

    /// Decoded placeholders, by hash and size.
    ///
    /// A card decodes its hash on the main thread as it mounts, and the same
    /// title turns up on Home, in its library and in Next Up, and mounts again
    /// every time a scrolled cell comes back. Each decode is a few thousand
    /// cosines; a lookup is one hash of a short string. NSCache is safe to use
    /// from any thread.
    nonisolated(unsafe) private static let decoded: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        // 32×32 at four bytes a pixel is 4 KB apiece.
        cache.countLimit = 800
        return cache
    }()

    /// Decode a hash into a small opaque image, or nil if the hash is malformed.
    /// `punch` raises the contrast of the AC components; 1 is faithful.
    static func image(from hash: String, width: Int = 32, height: Int = 32, punch: Float = 1) -> CGImage? {
        let key = "\(width)x\(height)x\(punch)|\(hash)" as NSString
        if let hit = decoded.object(forKey: key) { return hit }
        guard let image = decode(hash, width: width, height: height, punch: punch) else { return nil }
        decoded.setObject(image, forKey: key)
        return image
    }

    private static func decode(_ hash: String, width: Int, height: Int, punch: Float) -> CGImage? {
        guard hash.count >= 6 else { return nil }
        let chars = Substring(hash)

        let sizeFlag = decode83(chars.prefix(1))
        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1
        guard hash.count == 4 + 2 * numX * numY else { return nil }

        let quantisedMax = decode83(chars.dropFirst(1).prefix(1))
        let maxValue = Float(quantisedMax + 1) / 166

        var colours = [(Float, Float, Float)](repeating: (0, 0, 0), count: numX * numY)

        // DC term: a plain sRGB triple.
        let dc = decode83(chars.dropFirst(2).prefix(4))
        colours[0] = (
            sRGBToLinear((dc >> 16) & 255),
            sRGBToLinear((dc >> 8) & 255),
            sRGBToLinear(dc & 255)
        )

        // AC terms: each a base-83 pair encoding three signed components.
        for i in 1..<(numX * numY) {
            let start = 6 + (i - 1) * 2
            let value = decode83(chars.dropFirst(start).prefix(2))
            let r = Float(value / (19 * 19))
            let g = Float((value / 19) % 19)
            let b = Float(value % 19)
            colours[i] = (
                signPow((r - 9) / 9, 2) * maxValue * punch,
                signPow((g - 9) / 9, 2) * maxValue * punch,
                signPow((b - 9) / 9, 2) * maxValue * punch
            )
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        // Cosine bases are the same for every row/column, so they're computed
        // once rather than inside the inner loop.
        var cosX = [Float](repeating: 0, count: width * numX)
        for x in 0..<width {
            for i in 0..<numX {
                cosX[x * numX + i] = cosf(Float.pi * Float(x) * Float(i) / Float(width))
            }
        }

        for y in 0..<height {
            var cosY = [Float](repeating: 0, count: numY)
            for j in 0..<numY {
                cosY[j] = cosf(Float.pi * Float(y) * Float(j) / Float(height))
            }
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis = cosX[x * numX + i] * cosY[j]
                        let c = colours[i + j * numX]
                        r += c.0 * basis
                        g += c.1 * basis
                        b += c.2 * basis
                    }
                }
                let o = (y * width + x) * 4
                pixels[o] = linearToSRGB(r)
                pixels[o + 1] = linearToSRGB(g)
                pixels[o + 2] = linearToSRGB(b)
                pixels[o + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
