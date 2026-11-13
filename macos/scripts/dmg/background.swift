//
//  background.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
//
// Draws the .dmg window's background: the burn line itself. A usage chart
// runs from Burnline to Applications, and its trend line is a lit fuse: the
// bars it has burnt past glow, the ones ahead wait, and the spark travels
// toward Applications, the way to drag. Below, the one first-open step an
// un-notarized app needs, and why, large enough to follow without squinting.
// A nightly's window is the same under its night sky.
//
//   swift macos/scripts/dmg/background.swift <output.png> <scale> [--nightly]
//
// The layout is shared with settings.py, which places the icons; the window
// is `Layout.size` points.

import AppKit

enum Layout {
    static let size = CGSize(width: 720, height: 540)
    /// Centres of Burnline's icon and the Applications link, as settings.py places them.
    static let app = CGPoint(x: 180, y: 172)
    static let applications = CGPoint(x: 540, y: 172)
    static let iconRadius: CGFloat = 60
    static let chartBase: CGFloat = 262
    /// Ends well clear of the bottom edge, where Finder may draw a path bar.
    static let panel = CGRect(x: 28, y: 288, width: 664, height: 214)
    /// Finder writes each icon's name in dark grey whatever lies behind it,
    /// so each name sits on a light tag of its own, centred this far down.
    static let labelY: CGFloat = 246
    static let labels: [(center: CGFloat, width: CGFloat)] = [(app.x, 84), (applications.x, 104)]
    /// How far along the fuse the spark has burnt.
    static let burnt: CGFloat = 0.58
}

enum Palette {
    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
    static let background = hex(0x0A0A0A)
    static let surface = hex(0x121212)
    static let rim = hex(0x2C2C2C)
    static let textPrimary = hex(0xF5F5F5)
    static let textSecondary = hex(0x8E8E8E)
    static let inactive = hex(0x4A4A4A)
    static let ember = hex(0xFF8A4C)
    static let emberDeep = hex(0xD9530F)
    static let whiteHot = hex(0xFFF1E0)
    static let nightTop = hex(0x0D1238)
    static let nightBottom = hex(0x45216F)
    static let moonlight = hex(0xC9BEFF)
}

/// The fuse: a cord that sags a little between the two icons.
struct Fuse {
    let start = CGPoint(x: Layout.app.x + Layout.iconRadius + 6, y: Layout.app.y + 4)
    let end = CGPoint(x: Layout.applications.x - Layout.iconRadius - 12, y: Layout.applications.y + 4)
    var control: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: start.y + 34) }

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    /// The parameter whose point is at `x`, by bisection: x rises along the cord.
    func t(atX x: CGFloat) -> CGFloat {
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if point(mid).x < x { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    func path(from a: CGFloat, to b: CGFloat, steps: Int = 80) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(a))
        for i in 1...steps { path.addLine(to: point(a + (b - a) * CGFloat(i) / CGFloat(steps))) }
        return path
    }
}

/// A fixed sequence, so every build draws the same sparks and stars.
struct Seeded {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let scale = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: background.swift <output.png> <scale> [--nightly]\n".utf8))
    exit(2)
}
let output = URL(filePath: arguments[1])
let nightly = arguments.contains("--nightly")

let pixels = CGSize(width: Layout.size.width * scale, height: Layout.size.height * scale)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = Layout.size
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = graphics
let context = graphics.cgContext
// Top-left origin, as the layout is written.
context.translateBy(x: 0, y: Layout.size.height)
context.scaleBy(x: 1, y: -1)
let flipped = NSGraphicsContext(cgContext: context, flipped: true)
NSGraphicsContext.current = flipped

let bounds = CGRect(origin: .zero, size: Layout.size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations)!
}

func glow(at center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
    context.drawRadialGradient(gradient([color.withAlphaComponent(alpha), color.withAlphaComponent(0)], [0, 1]),
                               startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                               options: [])
}

// Sky or graphite.
if nightly {
    context.drawLinearGradient(gradient([Palette.nightTop, Palette.nightBottom], [0, 1]),
                               start: .zero, end: CGPoint(x: bounds.width, y: bounds.height),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    var random = Seeded(state: 11)
    for _ in 0..<70 {
        let star = CGPoint(x: random.next() * bounds.width, y: random.next() * Layout.panel.minY)
        let size = 0.6 + random.next() * 1.3
        context.setFillColor(NSColor.white.withAlphaComponent(0.25 + random.next() * 0.55).cgColor)
        context.fillEllipse(in: CGRect(x: star.x, y: star.y, width: size, height: size))
    }
    // A crescent, as on the nightly icon: a disc with a disc cut away.
    let moon = CGPoint(x: bounds.width - 62, y: 52)
    glow(at: moon, radius: 54, color: Palette.moonlight, alpha: 0.22)
    context.saveGState()
    let disc = CGRect(x: moon.x - 17, y: moon.y - 17, width: 34, height: 34)
    context.addEllipse(in: disc)
    context.clip()
    context.addRect(bounds)
    context.addEllipse(in: disc.offsetBy(dx: 10, dy: -8))
    context.clip(using: .evenOdd)
    context.setFillColor(Palette.moonlight.cgColor)
    context.fill(bounds)
    context.restoreGState()
} else {
    context.setFillColor(Palette.background.cgColor)
    context.fill(bounds)
    // The flame lights the graphite around the spark, and nothing else.
    glow(at: CGPoint(x: bounds.midX, y: 190), radius: 360, color: Palette.hex(0x1C1C1C), alpha: 1)
}

// A faint chart grid behind it all.
context.setStrokeColor(NSColor.white.withAlphaComponent(nightly ? 0.05 : 0.035).cgColor)
context.setLineWidth(1)
for y in stride(from: Layout.chartBase - 96, through: Layout.chartBase, by: 32) {
    context.move(to: CGPoint(x: 24, y: y + 0.5))
    context.addLine(to: CGPoint(x: bounds.width - 24, y: y + 0.5))
}
context.strokePath()

let fuse = Fuse()
let spark = fuse.point(Layout.burnt)

// The chart: a bar under each step of the cord, reaching up to it. Burnt
// bars are spent usage and still glow; the bars ahead are what remains.
let barWidth: CGFloat = 6, barGap: CGFloat = 5
for x in stride(from: fuse.start.x + 6, through: fuse.end.x - 6, by: barWidth + barGap) {
    let t = fuse.t(atX: x + barWidth / 2)
    let top = fuse.point(t).y + 9
    let bar = CGRect(x: x, y: top, width: barWidth, height: Layout.chartBase - top)
    let path = CGPath(roundedRect: bar, cornerWidth: 2, cornerHeight: 2, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    if t < Layout.burnt {
        // Hotter the nearer the spark.
        let heat = 0.25 + 0.55 * pow(t / Layout.burnt, 2)
        context.drawLinearGradient(gradient([Palette.ember.withAlphaComponent(heat),
                                             Palette.emberDeep.withAlphaComponent(heat * 0.15)], [0, 1]),
                                   start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: Layout.chartBase), options: [])
    } else {
        context.setFillColor(NSColor.white.withAlphaComponent(nightly ? 0.10 : 0.07).cgColor)
        context.fill(bar)
    }
    context.restoreGState()
}

// The cord ahead of the spark: twisted, waiting.
context.setLineCap(.round)
context.addPath(fuse.path(from: Layout.burnt, to: 1))
context.setStrokeColor((nightly ? Palette.moonlight.withAlphaComponent(0.55) : Palette.hex(0x8A8A8A)).cgColor)
context.setLineWidth(3)
context.strokePath()
context.setLineDash(phase: 0, lengths: [2, 3])
context.addPath(fuse.path(from: Layout.burnt, to: 1))
context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
context.setLineWidth(3)
context.strokePath()
context.setLineDash(phase: 0, lengths: [])

// The arrowhead it burns toward.
let tip = fuse.point(1), before = fuse.point(0.97)
let angle = atan2(tip.y - before.y, tip.x - before.x)
let head = CGMutablePath()
head.move(to: CGPoint(x: tip.x - 10 * cos(angle - 0.55), y: tip.y - 10 * sin(angle - 0.55)))
head.addLine(to: tip)
head.addLine(to: CGPoint(x: tip.x - 10 * cos(angle + 0.55), y: tip.y - 10 * sin(angle + 0.55)))
context.addPath(head)
context.setStrokeColor(Palette.ember.cgColor)
context.setLineWidth(2.5)
context.setLineJoin(.round)
context.strokePath()

// The burnt cord: ash, still red near the spark.
context.addPath(fuse.path(from: 0, to: Layout.burnt))
context.setStrokeColor(Palette.inactive.withAlphaComponent(0.8).cgColor)
context.setLineWidth(2)
context.strokePath()
context.saveGState()
context.addPath(fuse.path(from: Layout.burnt * 0.55, to: Layout.burnt))
context.setLineWidth(2.4)
context.replacePathWithStrokedPath()
context.clip()
context.drawLinearGradient(gradient([Palette.ember.withAlphaComponent(0), Palette.ember], [0, 1]),
                           start: fuse.point(Layout.burnt * 0.55), end: spark, options: [])
context.restoreGState()

// The spark: a glow, a white-hot core, and a few flecks thrown forward.
glow(at: spark, radius: 46, color: Palette.ember, alpha: 0.30)
glow(at: spark, radius: 16, color: Palette.ember, alpha: 0.85)
glow(at: spark, radius: 6, color: Palette.whiteHot, alpha: 1)
var random = Seeded(state: 7)
for _ in 0..<16 {
    let direction = -.pi * 0.9 + random.next() * .pi * 1.1
    let reach = 9 + random.next() * 22
    let fleck = CGPoint(x: spark.x + cos(direction) * reach, y: spark.y + sin(direction) * reach)
    let size = 0.8 + random.next() * 1.4
    context.setFillColor((random.next() < 0.5 ? Palette.whiteHot : Palette.ember)
        .withAlphaComponent(0.5 + random.next() * 0.5).cgColor)
    context.fillEllipse(in: CGRect(x: fleck.x - size / 2, y: fleck.y - size / 2, width: size, height: size))
}

// A tag under each icon for Finder's dark name to sit on.
for label in Layout.labels {
    let tag = CGRect(x: label.center - label.width / 2, y: Layout.labelY - 11, width: label.width, height: 22)
    context.addPath(CGPath(roundedRect: tag, cornerWidth: 11, cornerHeight: 11, transform: nil))
    context.setFillColor(Palette.hex(0xE8E8E8, 0.94).cgColor)
    context.fillPath()
}

// Words.
func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          width: CGFloat? = nil, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineSpacing = 2
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                     .foregroundColor: color, .paragraphStyle: style]
    let string = NSAttributedString(string: text, attributes: attributes)
    if let width {
        string.draw(with: CGRect(x: point.x, y: point.y, width: width, height: 200),
                    options: [.usesLineFragmentOrigin])
    } else {
        string.draw(at: point)
    }
}

let title = nightly ? "Burnline Nightly" : "Burnline"
draw(title, at: CGPoint(x: 0, y: 30), size: 22, weight: .bold,
     color: nightly ? Palette.moonlight : Palette.textPrimary, width: bounds.width, alignment: .center)
draw("Drag the flame along the fuse, into Applications.", at: CGPoint(x: 0, y: 62), size: 12.5, weight: .regular,
     color: nightly ? Palette.moonlight.withAlphaComponent(0.7) : Palette.textSecondary, width: bounds.width,
     alignment: .center)

// The first-open panel.
let panel = CGPath(roundedRect: Layout.panel, cornerWidth: 14, cornerHeight: 14, transform: nil)
context.addPath(panel)
context.setFillColor(nightly ? NSColor.black.withAlphaComponent(0.35).cgColor : Palette.surface.cgColor)
context.fillPath()
context.addPath(panel)
context.setStrokeColor(nightly ? Palette.moonlight.withAlphaComponent(0.18).cgColor : Palette.rim.cgColor)
context.setLineWidth(1)
context.strokePath()

let inset: CGFloat = 22
let accent = nightly ? Palette.moonlight : Palette.ember
let textWidth = Layout.panel.width - inset * 2
draw("Opening Burnline the first time", at: CGPoint(x: Layout.panel.minX + inset, y: Layout.panel.minY + 18),
     size: 16, weight: .semibold, color: Palette.textPrimary)
draw("Once only", at: CGPoint(x: Layout.panel.minX + inset, y: Layout.panel.minY + 21), size: 12, weight: .semibold,
     color: accent, width: textWidth, alignment: .right)
draw("macOS asks once because Burnline isn’t notarized: that takes a paid Apple developer account, and Burnline "
     + "is free and open source. Updates from within Burnline open straight away.",
     at: CGPoint(x: Layout.panel.minX + inset, y: Layout.panel.minY + 46), size: 12, weight: .regular,
     color: Palette.textSecondary, width: textWidth)
let steps = ["Open Burnline from Applications. When macOS can’t verify the developer, choose Done.",
             "Open System Settings, then Privacy & Security, and scroll down to Security.",
             "Choose Open Anyway beside Burnline, then confirm with your password or Touch ID."]
for (index, step) in steps.enumerated() {
    let x = Layout.panel.minX + inset
    let y = Layout.panel.minY + 98 + CGFloat(index) * 38
    let badge = CGRect(x: x, y: y, width: 24, height: 24)
    context.setFillColor(accent.withAlphaComponent(0.16).cgColor)
    context.fillEllipse(in: badge)
    draw("\(index + 1)", at: CGPoint(x: badge.minX, y: badge.minY + 3.5), size: 13, weight: .bold,
         color: accent, width: badge.width, alignment: .center)
    draw(step, at: CGPoint(x: x + 36, y: y + 3), size: 14, weight: .regular,
         color: Palette.textPrimary.withAlphaComponent(0.92), width: textWidth - 36)
}

NSGraphicsContext.current = nil
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: output)
