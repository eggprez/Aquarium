import Foundation
import AppKit

let stage = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./stage"

// ---------------------------------------------------------------- iOS + macOS

let appIcon = "\(stage)/AppIcon.appiconset"

savePNGOpaque(squareIcon(size: 1024, treatment: .bright), "\(appIcon)/icon-1024.png")
savePNG(squareIcon(size: 1024, treatment: .darkVariant), "\(appIcon)/icon-1024-dark.png")
savePNG(squareIcon(size: 1024, treatment: .mono), "\(appIcon)/icon-1024-tinted.png")

// macOS wants the corners baked in, on Apple's 824-in-1024 grid, with a shadow.
let macGrid: CGFloat = 824.0 / 1024.0
for (name, px) in [("mac-16x16@1x", 16), ("mac-16x16@2x", 32),
                   ("mac-32x32@1x", 32), ("mac-32x32@2x", 64),
                   ("mac-128x128@1x", 128), ("mac-128x128@2x", 256),
                   ("mac-256x256@1x", 256), ("mac-256x256@2x", 512),
                   ("mac-512x512@1x", 512), ("mac-512x512@2x", 1024)] {
    savePNG(roundedTile(size: px, tileFraction: macGrid, shadow: px >= 64), "\(appIcon)/\(name).png")
}

// ---------------------------------------------------------------- in-app logo

for (name, px) in [("logo", 88), ("logo@2x", 176), ("logo@3x", 264)] {
    savePNG(roundedTile(size: px, tileFraction: 1.0, shadow: false), "\(stage)/Logo.imageset/\(name).png")
}

// ---------------------------------------------------------------- tvOS layers

enum Layer { case back, middle, front, bubbles }

func tvLayer(_ layer: Layer, w: Int, h: Int) -> CGContext {
    let ctx = ctxMake(w, h)
    let r = CGRect(x: 0, y: 0, width: w, height: h)
    let side = CGFloat(h) * 0.88
    let box = CGRect(x: (CGFloat(w) - side)/2, y: (CGFloat(h) - side)/2, width: side, height: side)
    let mark = ringMark()
    switch layer {
    case .back:
        paintBackground(ctx, r, .bright)
    case .middle:
        // depth only: the shadow the mark will cast once the front layer floats
        // above it under parallax
        paintShadowOnly(ctx, mark, box: box, color: rgb(0x2A1055, 0.45), blur: 46, offset: CGSize(width: 0, height: 18))
    case .front:
        // no baked shadow: the middle layer is the shadow, and under parallax
        // it has to be free to move independently of the mark
        paintMark(ctx, mark, box: box, .bright, shadow: false)
    case .bubbles:
        // their own layer, nearest the viewer, so they drift over the mark
        // under parallax; laid out round the mark the way the square icon has them
        let around = box.insetBy(dx: -CGFloat(h) * 0.04, dy: -CGFloat(h) * 0.04)
        paintBubbles(ctx, box: around)
    }
    return ctx
}

let brand = "\(stage)/App Icon.brandassets"

func writeStack(_ dir: String, sizes: [(String, Int, Int)]) {
    for (layer, name) in [(Layer.back, "Back"), (Layer.middle, "Middle"), (Layer.front, "Front"), (Layer.bubbles, "Bubbles")] {
        for (suffix, w, h) in sizes {
            let file = "\(dir)/\(name).imagestacklayer/Content.imageset/\(name.lowercased())-\(suffix).png"
            savePNG(tvLayer(layer, w: w, h: h), file)
        }
    }
}

writeStack("\(brand)/App Icon.imagestack",
           sizes: [("400x240@1x", 400, 240), ("400x240@2x", 800, 480)])
writeStack("\(brand)/App Icon - App Store.imagestack",
           sizes: [("1280x768@1x", 1280, 768)])

// ---------------------------------------------------------------- top shelf

func topShelf(w: Int, h: Int, scale: Int) -> CGContext {
    let W = w * scale, H = h * scale
    let ctx = ctxMake(W, H)
    let r = CGRect(x: 0, y: 0, width: W, height: H)
    darkBackground(ctx, r)

    let s = CGFloat(scale)
    let tileSide = CGFloat(h) * 0.40 * s
    let fontSize = CGFloat(h) * 0.20 * s
    let runs: [(String, NSFont.Weight, NSColor)] = [
        ("Aqua", .semibold, .white),
        ("rium", .heavy, NSColor(srgbRed: 0.71, green: 0.51, blue: 0.99, alpha: 1))
    ]
    let gap = tileSide * 0.30
    let total = tileSide + gap + textWidth(runs, size: fontSize)
    let left = (CGFloat(W) - total) / 2
    let midY = CGFloat(H) / 2

    let tile = roundedTile(size: Int(tileSide.rounded()), tileFraction: 1.0, shadow: false).makeImage()!
    let tileRect = CGRect(x: left, y: midY - tileSide/2, width: tileSide, height: tileSide)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 42 * s, color: rgb(0x000000, 0.55))
    ctx.translateBy(x: 0, y: tileRect.maxY + tileRect.minY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(tile, in: tileRect)
    ctx.restoreGState()

    drawText(ctx, runs, size: fontSize,
             centerAt: CGPoint(x: left + tileSide + gap + textWidth(runs, size: fontSize)/2, y: midY))
    return ctx
}

savePNG(topShelf(w: 1920, h: 720, scale: 1), "\(brand)/Top Shelf Image.imageset/topshelf@1x.png")
savePNG(topShelf(w: 1920, h: 720, scale: 2), "\(brand)/Top Shelf Image.imageset/topshelf@2x.png")
savePNG(topShelf(w: 2320, h: 720, scale: 1), "\(brand)/Top Shelf Image Wide.imageset/topshelfwide@1x.png")
savePNG(topShelf(w: 2320, h: 720, scale: 2), "\(brand)/Top Shelf Image Wide.imageset/topshelfwide@2x.png")

// ---------------------------------------------------------------- proof sheet

func proof() {
    let W = 1500, H = 1260
    let ctx = ctxMake(W, H)
    ctx.setFillColor(rgb(0x16161C))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    func label(_ s: String, _ p: CGPoint, _ size: CGFloat = 19, _ alpha: CGFloat = 0.55) {
        drawText(ctx, [(s, .medium, NSColor.white.withAlphaComponent(alpha))], size: size, centerAt: p)
    }
    func place(_ img: CGImage, _ rect: CGRect, mask: CGPath? = nil, backdrop: CGColor? = nil) {
        ctx.saveGState()
        if let mask { ctx.addPath(mask); ctx.clip() }
        if let backdrop { ctx.setFillColor(backdrop); ctx.fill(rect) }
        ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: rect)
        ctx.restoreGState()
    }

    drawText(ctx, [("Aquarium — Ring Play, installed", .semibold, .white)], size: 32,
             centerAt: CGPoint(x: CGFloat(W)/2, y: 56))

    // iOS: default / dark / tinted, each under the iOS mask
    let variants: [(String, Treatment, CGColor)] = [
        ("iOS default", .bright, rgb(0x000000, 0)),
        ("iOS dark", .darkVariant, rgb(0x1C1C1E)),
        ("iOS tinted", .mono, rgb(0x2C2C2E))
    ]
    for (i, (name, treatment, backdrop)) in variants.enumerated() {
        let x = 120 + CGFloat(i) * 250
        let rect = CGRect(x: x, y: 120, width: 200, height: 200)
        let img = squareIcon(size: 800, treatment: treatment).makeImage()!
        place(img, rect, mask: squircle(rect, n: 5.0), backdrop: backdrop)
        label(name, CGPoint(x: rect.midX, y: 344))
    }

    // macOS, at three of its real sizes
    var macX: CGFloat = 900
    for px in [128, 64, 32] {
        let shown = CGFloat(px) * 1.5
        let img = roundedTile(size: px * 4, tileFraction: macGrid, shadow: px >= 64).makeImage()!
        place(img, CGRect(x: macX, y: 320 - shown, width: shown, height: shown))
        macX += shown + 26
    }
    label("macOS 128 / 64 / 32 pt", CGPoint(x: 1090, y: 344))

    // tvOS: the three layers stacked, and pulled apart as the parallax does
    let tvW = 400, tvH = 240
    let stackRect = CGRect(x: 120, y: 430, width: 400, height: 240)
    let flat = ctxMake(tvW * 3, tvH * 3)
    // ctxMake is y-down; undo that for draw(), or the stack lands upside down
    flat.translateBy(x: 0, y: CGFloat(tvH * 3))
    flat.scaleBy(x: 1, y: -1)
    for l in [Layer.back, .middle, .front, .bubbles] {
        flat.draw(tvLayer(l, w: tvW * 3, h: tvH * 3).makeImage()!,
                  in: CGRect(x: 0, y: 0, width: tvW * 3, height: tvH * 3))
    }
    place(flat.makeImage()!, stackRect, mask: roundRect(stackRect, 24))
    label("tvOS 400×240, layers composited", CGPoint(x: stackRect.midX, y: 700))

    for (i, l) in [Layer.bubbles, .front, .back].enumerated() {
        let rect = CGRect(x: 620 + CGFloat(i) * 290, y: 470, width: 260, height: 156)
        ctx.saveGState()
        ctx.addPath(roundRect(rect, 14))
        ctx.clip()
        ctx.setFillColor(rgb(0x0E0E14))   // so a transparent layer reads as transparent
        ctx.fill(rect)
        ctx.restoreGState()
        place(tvLayer(l, w: 260 * 3, h: 156 * 3).makeImage()!, rect, mask: roundRect(rect, 14))
        label(["Bubbles", "Front", "Back"][i], CGPoint(x: rect.midX, y: 650), 16, 0.45)
    }
    label("the three parallax layers", CGPoint(x: 1055, y: 700))

    // top shelf
    let tsW: CGFloat = 1120, tsH = tsW * 720 / 1920
    let tsRect = CGRect(x: (CGFloat(W) - tsW)/2, y: 780, width: tsW, height: tsH)
    label("top shelf, 1920×720", CGPoint(x: CGFloat(W)/2, y: 752))
    place(topShelf(w: 1920, h: 720, scale: 1).makeImage()!, tsRect, mask: roundRect(tsRect, 16))

    savePNG(ctx, "\(stage)/proof.png")
}
proof()

print("staged in \(stage)")
