//  Rewrites PNGs in place as 8-bit sRGB. Icon Composer's export tool writes
//  16-bit-per-channel PNGs, which no display can show and which the asset
//  compiler stores at twice the size (ARGB-16). app_icons.py runs this over
//  the picker's preview tiles after rendering them.
//
//      swiftc -O png8.swift -o png8 && ./png8 a.png b.png ...

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("png8: cannot read \(path)\n".utf8))
        exit(1)
    }
    guard image.bitsPerComponent > 8 else { continue }
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("png8: cannot convert \(path)\n".utf8))
        exit(1)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("png8: cannot write \(path)\n".utf8))
        exit(1)
    }
}
