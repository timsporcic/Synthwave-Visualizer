// Generates the app icon. Run from the repo root:
//
//   swift scripts/make-icon.swift /tmp/icon.png
//   for s in 16 32 128 256 512; do for m in 1 2; do px=$((s*m))
//     sips -z $px $px /tmp/icon.png --out "Synthwave-Visualizer/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@${m}x.png"
//   done; done
//
// The artwork is full-bleed; macOS 26 applies the rounded-square mask.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the app icon at 1024x1024: synthwave sky, striped sun on the horizon,
// mirrored spectrum bars, and a cyan perspective grid. Palette from the plan.

let S: CGFloat = 1024
let out = CommandLine.arguments[1]

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let background: UInt32 = 0x0d0221
let purple: UInt32 = 0x8c1eff
let magenta: UInt32 = 0xff2975
let hotPink: UInt32 = 0xf222ff
let orange: UInt32 = 0xff901f
let cyan: UInt32 = 0x2de2e6
let sunHighlight: UInt32 = 0xffd319

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in top-left-origin coordinates.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space,
               colors: stops.map { rgb($0.0, $0.2) } as CFArray,
               locations: stops.map { $0.1 })!
}

let horizon = S * 0.60
let cx = S / 2

// Sky.
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: horizon))
ctx.drawLinearGradient(gradient([(background, 0, 1), (background, 0.08, 1), (purple, 0.42, 1),
                                 (magenta, 0.78, 1), (orange, 1.0, 1)]),
                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon), options: [])
ctx.restoreGState()

// Sun glow.
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: horizon))
ctx.drawRadialGradient(gradient([(hotPink, 0, 0.55), (magenta, 0.5, 0.25), (magenta, 1, 0)]),
                       startCenter: CGPoint(x: cx, y: horizon), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: horizon), endRadius: S * 0.48, options: [])
ctx.restoreGState()

// Sun: half disc with horizontal cut lines that widen toward the horizon.
let sunR = S * 0.27
let sunTop = horizon - sunR
ctx.saveGState()
let sunPath = CGMutablePath()
sunPath.addArc(center: CGPoint(x: cx, y: horizon), radius: sunR, startAngle: .pi, endAngle: 0, clockwise: false)
sunPath.closeSubpath()
ctx.addPath(sunPath)
ctx.clip()
ctx.addRect(CGRect(x: 0, y: 0, width: S, height: S))
// Cut lines: remove bands from the lower part of the sun.
var cuts: [CGRect] = []
var y = sunTop + sunR * 0.42
var h = S * 0.008
while y < horizon {
    cuts.append(CGRect(x: 0, y: y, width: S, height: h))
    y += h + S * 0.034 - h * 0.35
    h *= 1.45
}
for c in cuts { ctx.addRect(c) }
ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(gradient([(sunHighlight, 0, 1), (orange, 0.5, 1), (magenta, 1, 1)]),
                       start: CGPoint(x: 0, y: sunTop), end: CGPoint(x: 0, y: horizon), options: [])
ctx.restoreGState()

// Ground.
ctx.setFillColor(rgb(background))
ctx.fill(CGRect(x: 0, y: horizon, width: S, height: S - horizon))
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: horizon, width: S, height: S - horizon))
ctx.drawLinearGradient(gradient([(purple, 0, 0.55), (purple, 0.35, 0.12), (background, 1, 0)]),
                       start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: S), options: [])
ctx.restoreGState()

// Grid.
func glowLine(_ a: CGPoint, _ b: CGPoint, width: CGFloat, alpha: CGFloat) {
    ctx.setLineCap(.butt)
    ctx.move(to: a); ctx.addLine(to: b)
    ctx.setStrokeColor(rgb(magenta, 0.35 * alpha)); ctx.setLineWidth(width * 3.2); ctx.strokePath()
    ctx.move(to: a); ctx.addLine(to: b)
    ctx.setStrokeColor(rgb(cyan, alpha)); ctx.setLineWidth(width); ctx.strokePath()
}
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: horizon, width: S, height: S - horizon))
let depth = S - horizon
// Horizontal lines: y = horizon + depth * k / z, spaced evenly in z.
for i in 0..<7 {
    let z = 1.0 + CGFloat(i) * 0.85
    let ly = horizon + depth * 0.98 / z
    let t = (ly - horizon) / depth
    glowLine(CGPoint(x: 0, y: ly), CGPoint(x: S, y: ly), width: 2 + 7 * t, alpha: 0.35 + 0.65 * t)
}
// Vertical lines converge on the sun center.
for i in -7...7 {
    let bottomX = cx + CGFloat(i) * S * 0.20
    glowLine(CGPoint(x: cx + CGFloat(i) * S * 0.012, y: horizon), CGPoint(x: bottomX, y: S),
             width: 7, alpha: 0.95)
}
ctx.restoreGState()
// Horizon line.
ctx.setFillColor(rgb(cyan, 0.9))
ctx.fill(CGRect(x: 0, y: horizon - 2, width: S, height: 4))

// Spectrum bars, mirrored around the sun, lowest band nearest it.
let heights: [CGFloat] = [0.27, 0.19, 0.23, 0.13]
let barW = S * 0.034
let gap = S * 0.014
let firstX = cx - sunR - S * 0.03 - barW
for (i, hh) in heights.enumerated() {
    let barH = S * hh
    for side in [-1.0, 1.0] as [CGFloat] {
        let x0 = firstX - CGFloat(i) * (barW + gap)
        let x = side < 0 ? x0 : (2 * cx - x0 - barW)
        let r = CGRect(x: x, y: horizon - barH, width: barW, height: barH)
        // Glow.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.03, color: rgb(hotPink, 0.9))
        ctx.setFillColor(rgb(magenta))
        ctx.fill(r)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.drawLinearGradient(gradient([(cyan, 0, 1), (hotPink, 0.7, 1), (magenta, 1, 1)]),
                               start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: horizon - barH), options: [])
        ctx.restoreGState()
        // Peak cap.
        ctx.setFillColor(rgb(0xffffff, 0.95))
        ctx.fill(CGRect(x: x, y: horizon - barH - S * 0.03, width: barW, height: S * 0.011))
    }
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
