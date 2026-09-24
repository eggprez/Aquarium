import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------- infrastructure

func ctxMake(_ w: Int, _ h: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)   // top-left origin, y down
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// PNG without an alpha channel — what the App Store demands of an iOS icon.
func savePNGOpaque(_ ctx: CGContext, _ path: String) {
    let src = ctx.makeImage()!
    let flat = CGContext(data: nil, width: src.width, height: src.height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    flat.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    flat.fill(CGRect(x: 0, y: 0, width: src.width, height: src.height))
    flat.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
    writeImage(flat.makeImage()!, path)
}

func savePNG(_ ctx: CGContext, _ path: String) { writeImage(ctx.makeImage()!, path) }

func writeImage(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff)/255, green: CGFloat((hex >> 8) & 0xff)/255,
            blue: CGFloat(hex & 0xff)/255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

/// Superellipse ~ Apple's continuous rounded square.
func squircle(_ r: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let a = r.width/2, b = r.height/2, cx = r.midX, cy = r.midY
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2/n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2/n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

/// Triangle with rounded corners, pointing right.
func playTriangle(center: CGPoint, width w: CGFloat, height h: CGFloat, radius: CGFloat) -> CGPath {
    let cx = center.x + w * 0.06     // optical centering
    let pts = [CGPoint(x: cx - w*0.45, y: center.y - h/2),
               CGPoint(x: cx + w*0.55, y: center.y),
               CGPoint(x: cx - w*0.45, y: center.y + h/2)]
    let p = CGMutablePath()
    let mid = CGPoint(x: (pts[0].x + pts[1].x)/2, y: (pts[0].y + pts[1].y)/2)
    p.move(to: mid)
    for i in 0..<3 {
        p.addArc(tangent1End: pts[(i+1) % 3], tangent2End: pts[(i+2) % 3], radius: radius)
    }
    p.closeSubpath()
    return p
}

func roundRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// ---------------------------------------------------------------- the mark
// Authored inside a 1024x1024 design box. `holed` is filled even-odd so it can
// carry cutouts; `solid` is filled non-zero.

struct Mark { var holed: CGPath? = nil; var solid: CGPath? = nil }

/// The squircle ring the app already wore, with a play triangle living inside it.
/// `weight` thins the ring for very small renderings, where a heavy ring closes up.
func ringMark(weight: CGFloat = 1.0) -> Mark {
    let outer = CGRect(x: 190, y: 190, width: 644, height: 644)
    let ring = CGMutablePath()
    ring.addPath(squircle(outer, n: 4.2))
    ring.addPath(squircle(outer.insetBy(dx: 104 * weight, dy: 104 * weight), n: 4.0))
    let tri = playTriangle(center: CGPoint(x: 512, y: 512), width: 248, height: 268, radius: 36)
    return Mark(holed: ring, solid: tri)
}

// ---------------------------------------------------------------- painting

enum Treatment {
    case bright        // white mark on the brand gradient
    case darkVariant   // white mark and a violet glow, background left clear
    case mono          // flat white mark, background left clear
}

func paintBackground(_ ctx: CGContext, _ rect: CGRect, _ treatment: Treatment) {
    guard treatment == .bright else { return }
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawLinearGradient(gradient([(0.00, rgb(0xC26BFB)), (0.48, rgb(0x7C4DEE)), (1.00, rgb(0x2C7EF0))]),
                           start: CGPoint(x: rect.minX, y: rect.minY),
                           end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    // soft light from the top-left
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.30)), (1, rgb(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: rect.minX + rect.width*0.24, y: rect.minY + rect.height*0.10),
                           startRadius: 0,
                           endCenter: CGPoint(x: rect.minX + rect.width*0.24, y: rect.minY + rect.height*0.10),
                           endRadius: max(rect.width, rect.height) * 0.72, options: [])
    ctx.restoreGState()
}

func darkBackground(_ ctx: CGContext, _ rect: CGRect) {
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawLinearGradient(gradient([(0, rgb(0x171826)), (1, rgb(0x0A0A12))]),
                           start: CGPoint(x: rect.minX, y: rect.minY),
                           end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0x7C4DEE, 0.38)), (0.6, rgb(0x5B3BD6, 0.10)), (1, rgb(0x000000, 0))]),
                           startCenter: CGPoint(x: rect.midX, y: rect.midY),
                           startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY),
                           endRadius: max(rect.width, rect.height) * 0.55, options: [])
    ctx.restoreGState()
}

/// Fill only the shadow a shape would cast, and not the shape — used for the
/// tvOS middle layer, which is nothing but depth.
func paintShadowOnly(_ ctx: CGContext, _ mark: Mark, box: CGRect, color: CGColor,
                     blur: CGFloat, offset: CGSize) {
    let s = box.width / 1024
    let xf = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: s, y: s)
    let all = CGMutablePath()
    if let h = mark.holed { all.addPath(h, transform: xf) }
    if let f = mark.solid { all.addPath(f, transform: xf) }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: offset.width * s, height: offset.height * s),
                  blur: blur * s, color: color)
    ctx.addPath(all)
    // all but invisible, so what lands on the layer is the blur and nothing else:
    // a hard black edge here would peek out from behind the mark under parallax
    ctx.setFillColor(rgb(0x000000, 0.001))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// Draw the mark from its 1024 design box, fitted into `box`.
func paintMark(_ ctx: CGContext, _ mark: Mark, box: CGRect, _ treatment: Treatment,
               shadow: Bool = true) {
    let s = box.width / 1024
    var xf = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: s, y: s)

    // one flattened silhouette pass, so the shadow is cast by the whole mark
    // rather than by each piece against its neighbour
    if treatment != .mono && shadow {
        let all = CGMutablePath()
        if let h = mark.holed { all.addPath(h, transform: xf) }
        if let f = mark.solid { all.addPath(f, transform: xf) }
        ctx.saveGState()
        switch treatment {
        case .bright:      ctx.setShadow(offset: CGSize(width: 0, height: 14 * s), blur: 40 * s, color: rgb(0x2A1055, 0.34))
        case .darkVariant: ctx.setShadow(offset: .zero, blur: 96 * s, color: rgb(0xA855F7, 0.9))
        case .mono:        break
        }
        ctx.addPath(all)
        ctx.setFillColor(rgb(0xFFFFFF, 0.001))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    ctx.saveGState()
    if treatment == .darkVariant && shadow {
        ctx.setShadow(offset: .zero, blur: 64 * s, color: rgb(0xB98CFF, 0.65))
    } else if treatment == .bright && shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: 12 * s), blur: 30 * s, color: rgb(0x2A1055, 0.28))
    }
    ctx.setFillColor(rgb(0xFFFFFF))
    if let h = mark.holed { ctx.addPath(h.copy(using: &xf)!); ctx.fillPath(using: .evenOdd) }
    if let f = mark.solid { ctx.addPath(f.copy(using: &xf)!); ctx.fillPath(using: .winding) }
    ctx.restoreGState()

    guard treatment == .bright else { return }

    // a whisper of vertical shading, so the white isn't dead flat
    ctx.saveGState()
    if let h = mark.holed { ctx.addPath(h.copy(using: &xf)!) }
    if let f = mark.solid { ctx.addPath(f.copy(using: &xf)!) }
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0)), (1, rgb(0x6E4BC9, 0.16))]),
                           start: CGPoint(x: box.minX, y: box.minY),
                           end: CGPoint(x: box.minX, y: box.maxY), options: [])
    ctx.restoreGState()
}

// ---------------------------------------------------------------- bubbles

/// The Aquarium bubble trail, (cx, cy, r) on the 1024 design canvas — the same
/// list as BUBBLES in app_icons.py, so the tvOS icon and the logo match the
/// iOS and macOS icons.
let bubbles: [(CGFloat, CGFloat, CGFloat)] = [
    (834, 852, 86), (914, 698, 48), (846, 584, 31), (914, 480, 21), (862, 398, 13),
    (168, 182, 46), (262, 102, 25), (114, 296, 16),
]

/// Paint the bubbles fitted into `box`, lit by hand: a clear film darker at the
/// rim, a bright rim, a specular highlight top-left and a faint bounce
/// bottom-right. `minPixels` drops any bubble that would render smaller than
/// that, so tiny icons don't fill with specks.
func paintBubbles(_ ctx: CGContext, box: CGRect, minPixels: CGFloat = 5) {
    let s = box.width / 1024
    for (x, y, r) in bubbles {
        let c = CGPoint(x: box.minX + x * s, y: box.minY + y * s)
        let R = r * s
        guard R * 2 >= minPixels else { continue }
        let disc = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.06)), (0.72, rgb(0xFFFFFF, 0.14)),
                                         (1, rgb(0xFFFFFF, 0.42))]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: R, options: [])
        // bounce light off the bottom-right of the film
        let b = CGPoint(x: c.x + R * 0.42, y: c.y + R * 0.46)
        ctx.drawRadialGradient(gradient([(0, rgb(0xBFE9FF, 0.35)), (1, rgb(0xBFE9FF, 0))]),
                               startCenter: b, startRadius: 0, endCenter: b, endRadius: R * 0.55, options: [])
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: R * 0.06), blur: R * 0.25, color: rgb(0x10204A, 0.25))
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.88))
        ctx.setLineWidth(max(0.8, R * 0.09))
        ctx.strokeEllipse(in: disc.insetBy(dx: R * 0.045, dy: R * 0.045))
        ctx.restoreGState()

        // specular highlight
        ctx.saveGState()
        ctx.translateBy(x: c.x - R * 0.38, y: c.y - R * 0.40)
        ctx.rotate(by: -40 * .pi / 180)
        let hl = CGRect(x: -R * 0.27, y: -R * 0.16, width: R * 0.54, height: R * 0.32)
        ctx.addEllipse(in: hl)
        ctx.clip()
        ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 1)), (1, rgb(0xFFFFFF, 0.55))]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: R * 0.27, options: [])
        ctx.restoreGState()
    }
}

// ---------------------------------------------------------------- compositions

/// How much of the tile the mark spans. Small renderings get a slightly larger,
/// slightly thinner mark, which is what keeps a 16pt icon from turning to soup.
func markInset(forPixelSize px: CGFloat) -> (inset: CGFloat, weight: CGFloat) {
    switch px {
    case ..<40:  return (0.92, 0.80)
    case ..<128: return (0.88, 0.90)
    default:     return (0.84, 1.00)
    }
}

/// A full-bleed square icon: iOS masks the corners itself, so none are baked in.
func squareIcon(size: Int, treatment: Treatment) -> CGContext {
    let ctx = ctxMake(size, size)
    let r = CGRect(x: 0, y: 0, width: size, height: size)
    paintBackground(ctx, r, treatment)
    let (inset, weight) = markInset(forPixelSize: CGFloat(size))
    let m = CGFloat(size) * (1 - inset) / 2
    paintMark(ctx, ringMark(weight: weight), box: r.insetBy(dx: m, dy: m), treatment)
    paintBubbles(ctx, box: r)
    return ctx
}

/// A rounded tile with the corners baked in — for macOS, and for the in-app logo.
func roundedTile(size: Int, tileFraction: CGFloat, shadow: Bool) -> CGContext {
    let ctx = ctxMake(size, size)
    let s = CGFloat(size)
    let side = s * tileFraction
    let tile = CGRect(x: (s - side)/2, y: (s - side)/2, width: side, height: side)
    let shape = squircle(tile, n: 5.0)

    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: side * 0.022), blur: side * 0.05, color: rgb(0x000000, 0.32))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x000000, 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    paintBackground(ctx, tile, .bright)
    let (inset, weight) = markInset(forPixelSize: side)
    let m = side * (1 - inset) / 2
    paintMark(ctx, ringMark(weight: weight), box: tile.insetBy(dx: m, dy: m), .bright)
    paintBubbles(ctx, box: tile)
    ctx.restoreGState()
    return ctx
}

// ---------------------------------------------------------------- type

func drawText(_ ctx: CGContext, _ runs: [(String, NSFont.Weight, NSColor)], size: CGFloat,
              centerAt: CGPoint) {
    let attributed = NSMutableAttributedString()
    for (s, w, c) in runs {
        attributed.append(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: w),
            .foregroundColor: c
        ]))
    }
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    ctx.saveGState()
    ctx.translateBy(x: centerAt.x - w/2, y: centerAt.y + (ascent - descent)/2)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func textWidth(_ runs: [(String, NSFont.Weight, NSColor)], size: CGFloat) -> CGFloat {
    let attributed = NSMutableAttributedString()
    for (s, w, c) in runs {
        attributed.append(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: c
        ]))
    }
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
}
