//
//  PixelStory.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import CoreGraphics
import Foundation

/// One colour of the pixel scenes, and how much of what is beneath it covers.
struct Pixel: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8

    init(_ rgb: UInt32, alpha: Double = 1) {
        r = UInt8(rgb >> 16 & 0xFF)
        g = UInt8(rgb >> 8 & 0xFF)
        b = UInt8(rgb & 0xFF)
        a = UInt8((min(max(alpha, 0), 1) * 255).rounded())
    }

    static let white = Pixel(0xFFFFFF)
}

/// The four flame colours of a tier, for the scenes.
struct PixelPalette {
    let body: Pixel
    let shade: Pixel
    let inner: Pixel
    let core: Pixel

    init(_ colours: FlameColours) {
        body = Pixel(colours.body)
        shade = Pixel(colours.shade)
        inner = Pixel(colours.inner)
        core = Pixel(colours.core)
    }
}

/// A 340 × 100 framebuffer the story is drawn into a pixel at a time, as a
/// 16-bit game draws: whole pixels, no smoothing, translucent pixels blended
/// over what is beneath. Positions round to the nearest pixel, and anything
/// off the frame is dropped.
struct PixelBuffer {
    static let width = 340, height = 100, ground = 86

    private(set) var bytes = [UInt8](repeating: 255, count: width * height * 4)

    mutating func plot(_ x: Double, _ y: Double, _ colour: Pixel) {
        let column = Int(x.rounded()), row = Int(y.rounded())
        guard column >= 0, column < Self.width, row >= 0, row < Self.height, colour.a > 0 else { return }
        blend(at: (row * Self.width + column) * 4, colour)
    }

    mutating func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ colour: Pixel) {
        let left = Int(x.rounded()), top = Int(y.rounded())
        let first = max(0, left), last = min(Self.width, left + Int(w.rounded()))
        let firstRow = max(0, top), lastRow = min(Self.height, top + Int(h.rounded()))
        guard first < last, firstRow < lastRow, colour.a > 0 else { return }
        for row in firstRow..<lastRow {
            for column in first..<last { blend(at: (row * Self.width + column) * 4, colour) }
        }
    }

    private mutating func blend(at index: Int, _ colour: Pixel) {
        if colour.a == 255 {
            bytes[index] = colour.r
            bytes[index + 1] = colour.g
            bytes[index + 2] = colour.b
            return
        }
        let a = Int(colour.a), rest = 255 - a
        bytes[index] = UInt8((Int(colour.r) * a + Int(bytes[index]) * rest) / 255)
        bytes[index + 1] = UInt8((Int(colour.g) * a + Int(bytes[index + 1]) * rest) / 255)
        bytes[index + 2] = UInt8((Int(colour.b) * a + Int(bytes[index + 2]) * rest) / 255)
    }

    /// The frame as an opaque sRGB image.
    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Self.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Brushes

    /// Bands of sky, each seam dithered into the band above, top to bottom.
    mutating func sky(_ bands: [UInt32]) {
        let band = Double(Self.height) / Double(bands.count)
        for (index, colour) in bands.enumerated() {
            rect(0, Double(index) * band, Double(Self.width), band + 1, Pixel(colour))
            guard index > 0 else { continue }
            let above = Pixel(bands[index - 1]), y = Double(index) * band
            for x in stride(from: 0, to: Self.width, by: 2) {
                plot(Double(x + index % 2), y, above)
                plot(Double(x + 1 - index % 2), y + 1, above)
            }
        }
    }

    private static let starField: [(x: Double, y: Double, glow: Double)] = (0..<120).map {
        (Double(Int(scatter($0, 71) * Double(width))), Double(Int(scatter($0, 72) * 66)), scatter($0, 73))
    }

    /// Stars, all lit; the brightest are crosses.
    mutating func stars(count: Int) {
        for (x, y, glow) in Self.starField.prefix(count) {
            if glow > 0.93 {
                plot(x, y, .white)
                for (dx, dy) in Self.cross { plot(x + dx, y + dy, Pixel(0xFFFFFF, alpha: 0.45)) }
            } else {
                plot(x, y, Pixel(0xFFFFFF, alpha: glow > 0.6 ? 0.8 : 0.4))
            }
        }
    }

    /// Puts out the stars that are dark at `t`, by taking their pixels from
    /// `starless`, the same scenery drawn without stars.
    mutating func twinkle(t: Double, count: Int, starless: PixelBuffer) {
        for (x, y, glow) in Self.starField.prefix(count) where sin(t * 2 + glow * 40) < -0.4 {
            restore(Int(x), Int(y), from: starless)
            if glow > 0.93 { for (dx, dy) in Self.cross { restore(Int(x + dx), Int(y + dy), from: starless) } }
        }
    }

    private static let cross: [(Double, Double)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]

    private mutating func restore(_ x: Int, _ y: Int, from other: PixelBuffer) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        let index = (y * Self.width + x) * 4
        bytes[index] = other.bytes[index]
        bytes[index + 1] = other.bytes[index + 1]
        bytes[index + 2] = other.bytes[index + 2]
    }

    /// A wandering line of hills, filled to the bottom of the frame.
    mutating func ridge(seed: Int, base: Double, amplitude: Double, _ colour: UInt32) {
        var wander = 0.0
        for x in 0..<Self.width {
            wander = (wander + (scatter(seed, x, 81) - 0.5) * 1.6) * 0.96
            let y = (base - amplitude - wander * amplitude * 0.3 - sin(Double(x) / 31 + Double(seed)) * amplitude * 0.45).rounded()
            rect(Double(x), y, 1, Double(Self.height) - y, Pixel(colour))
        }
    }

    mutating func pine(_ x: Double, _ y: Double, size: Int, _ colour: UInt32) {
        for row in 0..<(size * 2) {
            let half = Double(row / 2)
            rect(x - half, y - Double(size * 2) + Double(row), half * 2 + 1, 1, Pixel(colour))
        }
        rect(x, y, 1, 2, Pixel(0x1A120C))
    }

    mutating func ground(_ colour: UInt32, edge: UInt32, seed: Int) {
        let top = Double(Self.ground)
        rect(0, top, Double(Self.width), Double(Self.height - Self.ground), Pixel(colour))
        for x in 0..<Self.width {
            if scatter(seed, x, 91) > 0.55 { plot(Double(x), top, Pixel(edge)) }
            if scatter(seed, x, 92) > 0.9 { plot(Double(x), top + 2 + Double(Int(scatter(seed, x, 93) * 10)), Pixel(edge)) }
        }
    }

    /// A filled circle, each pixel's colour chosen from its distance from the
    /// centre, as a share of the radius, and its offset.
    mutating func disc(_ cx: Double, _ cy: Double, radius: Int, tone: (Double, Int, Int) -> Pixel) {
        for j in -radius...radius {
            for i in -radius...radius {
                let distance = Double(i * i + j * j).squareRoot()
                if distance <= Double(radius) { plot(cx + Double(i), cy + Double(j), tone(distance / Double(radius), i, j)) }
            }
        }
    }

    mutating func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ colour: Pixel) {
        let steps = Int(max(abs(x1 - x0), abs(y1 - y0)))
        guard steps > 0 else { return plot(x0, y0, colour) }
        for step in 0...steps {
            let share = Double(step) / Double(steps)
            plot(x0 + (x1 - x0) * share, y0 + (y1 - y0) * share, colour)
        }
    }

    /// Fire rising from `base`: a teardrop sampled on the grid in four tones,
    /// shaded on the right, flickering apart near the tip.
    mutating func fire(_ cx: Double, base: Double, height: Int, width: Double, _ palette: PixelPalette, t: Double,
                       seed: Int = 0) {
        for y in 0..<height {
            let f = Double(y) / Double(height), half = width * sin(.pi * (0.38 + 0.62 * f)) * (1 - f * 0.15)
            let sway = (sin(t * 6 + Double(y) * 0.45 + Double(seed)) * f * 1.8).rounded()
            let reach = Int(half.rounded(.up))
            for x in -reach...reach {
                let d = Double(abs(x)) / max(1, half)
                if d > 1 || (f > 0.55 && scatter(x, y, Int(t * 12), seed) > 0.62) { continue }
                let colour = d < 0.35 && f < 0.55 ? palette.core
                    : d < 0.68 && f < 0.8 ? palette.inner : Double(x) > half * 0.4 ? palette.shade : palette.body
                plot(cx + Double(x) + sway, base - Double(y), colour)
            }
        }
    }

    /// Exhaust falling from a nozzle at `top`: hottest at the nozzle,
    /// flickering apart at the end.
    mutating func exhaust(_ cx: Double, top: Double, length: Int, width: Double, _ palette: PixelPalette, t: Double,
                          seed: Int = 0) {
        for y in 0..<max(0, length) {
            let f = Double(y) / Double(length), half = width * (1 - f * 0.7) + (y < 2 ? 0.4 : 0)
            let jitter = (sin(t * 24 + Double(y) * 1.3 + Double(seed)) * f).rounded()
            let reach = Int(half.rounded(.up))
            for x in -reach...reach {
                let d = Double(abs(x)) / max(0.6, half)
                if d > 1 || (f > 0.5 && scatter(x, y, Int(t * 18), seed) > 0.58) { continue }
                let colour = f < 0.3 && d < 0.55 ? palette.core : f < 0.62 && d < 0.85 ? palette.inner : palette.body
                plot(cx + Double(x) + jitter, top + Double(y), colour)
            }
        }
    }
}

/// The five chapters of Bot-7's story, each a scene that changes with the
/// tier: a campfire, a forge, a launch pad, a flight to the sun, and the
/// cosmos.
enum StoryChapter: Int, CaseIterable {
    case camp, forge, launch, sun, cosmos

    var title: String {
        switch self {
        case .camp: "Camp"
        case .forge: "The Forge"
        case .launch: "Launch"
        case .sun: "The Sun"
        case .cosmos: "Cosmos"
        }
    }

    /// The chapter a tier belongs to; before the first tier, the camp.
    static func of(tierIndex: Int?) -> StoryChapter {
        switch tierIndex ?? 0 {
        case ..<3: .camp
        case ..<6: .forge
        case ..<9: .launch
        case ..<11: .sun
        default: .cosmos
        }
    }

    /// Where Bot-7 stands, and whether it flies here.
    var bot: (x: Double, flies: Bool) {
        switch self {
        case .camp: (104, false)
        case .forge: (118, false)
        case .launch: (112, false)
        case .sun, .cosmos: (150, true)
        }
    }
}

/// Draws one frame of the story for a tier, at time `t` in seconds. Pure: the
/// same tier and time draw the same frame. `lit` false dims the scene while
/// today has no usage yet; `popAge` throws sparks for a newly reached tier.
///
/// The scenery that never moves is drawn once per tier and kept; each frame
/// starts from a copy of it and draws only what moves.
struct StoryPainter {
    let tierIndex: Int?
    var lit = true

    func frame(t: Double, popAge: Double? = nil) -> PixelBuffer {
        let chapter = StoryChapter.of(tierIndex: tierIndex), tier = tierIndex ?? -1
        let palette = PixelPalette(FlameLook.at(tierIndex).colours)
        let scenery = Self.scenery(tier: tier, chapter: chapter, palette: palette)
        var buffer = scenery.lit
        buffer.twinkle(t: t, count: Self.stars(chapter), starless: scenery.starless)
        switch chapter {
        case .camp: Self.animateCamp(&buffer, t: t, tier: tier, palette)
        case .forge: Self.animateForge(&buffer, t: t, tier: tier, palette)
        case .launch: Self.animateLaunch(&buffer, t: t, tier: tier, palette)
        case .sun: Self.animateSun(&buffer, t: t, tier: tier, palette)
        case .cosmos: Self.animateCosmos(&buffer, t: t, tier: tier, palette)
        }
        let (x, flies) = chapter.bot
        let origin = BotSeven.draw(&buffer, x: x, ground: flies ? 74 : Double(PixelBuffer.ground), t: t, chapter: chapter,
                                   palette: palette, flies: flies)
        if chapter == .forge { BotSeven.hammer(&buffer, left: origin.left, top: origin.top, t: t, palette, tier: tier) }
        if let popAge { Self.burst(&buffer, x: x, age: popAge, palette) }
        if !lit { buffer.rect(0, 0, Double(PixelBuffer.width), Double(PixelBuffer.height), Pixel(0x060810, alpha: 0.45)) }
        return buffer
    }

    /// The still scenery for each tier, with its stars lit and without them.
    private static var sceneryCache: [Int: (lit: PixelBuffer, starless: PixelBuffer)] = [:]

    private static func scenery(tier: Int, chapter: StoryChapter, palette: PixelPalette)
        -> (lit: PixelBuffer, starless: PixelBuffer) {
        if let cached = sceneryCache[tier] { return cached }
        let draw = { (stars: Bool) -> PixelBuffer in
            var buffer = PixelBuffer()
            let count = stars ? Self.stars(chapter) : 0
            switch chapter {
            case .camp: camp(&buffer, tier: tier, stars: count, palette)
            case .forge: forge(&buffer, tier: tier, palette)
            case .launch: launch(&buffer, stars: count)
            case .sun: sun(&buffer, tier: tier, stars: count, palette)
            case .cosmos: cosmos(&buffer, stars: count)
            }
            return buffer
        }
        let scenery = (lit: draw(true), starless: draw(false))
        sceneryCache[tier] = scenery
        return scenery
    }

    private static func stars(_ chapter: StoryChapter) -> Int {
        switch chapter {
        case .camp, .sun, .cosmos: 120
        case .launch: 30
        case .forge: 0
        }
    }

    private static func burst(_ g: inout PixelBuffer, x: Double, age: Double, _ palette: PixelPalette) {
        let life = 1 - age / 0.85
        guard age >= 0, life > 0 else { return }
        let frames = age * 60, colours = [palette.body, palette.inner, palette.core]
        for index in 0..<36 {
            let angle = scatter(index, 21) * 2 * .pi, speed = 0.5 + scatter(index, 22) * 1.4
            g.plot(x + cos(angle) * speed * frames, 62 + (sin(angle) * speed - 0.5) * frames + 0.015 * frames * frames,
                   colours[index % 3])
        }
    }

    // MARK: Camp: a night by a fire that grows from a struck match to a campfire

    private static let campfire = 168.0

    private static func camp(_ g: inout PixelBuffer, tier: Int, stars: Int, _ palette: PixelPalette) {
        let ground = Double(PixelBuffer.ground), fx = campfire
        g.sky([0x05060F, 0x070A1A, 0x0B1028, 0x101638, 0x151C46, 0x1B2352])
        g.stars(count: stars)
        g.disc(244, 18, radius: 7) { d, i, j in
            Pixel((i - 1) * (i - 1) + (j + 2) * (j + 2) < 4 ? 0xC9C4AA : i + j < -3 ? 0xFFFBEA : d > 0.8 ? 0xD0CBB2 : 0xECE8D4)
        }
        g.ridge(seed: 3, base: 64, amplitude: 10, 0x121630)
        g.ridge(seed: 9, base: 74, amplitude: 6, 0x0C1024)
        for index in 0..<25 { g.pine(Double(4 + index * 14 + index % 3 * 4), Double(85 - index % 2 * 2), size: 4 + index % 3, 0x080B18) }
        g.ground(0x17130F, edge: 0x251C13, seed: 1)
        guard tier >= 0 else { return }
        let glow = [8.0, 14, 22][min(tier, 2)]
        for y in PixelBuffer.ground..<PixelBuffer.height {
            for x in Int(fx - glow * 2)...Int(fx + glow * 2) {
                let dx = (Double(x) - fx) / (glow * 2), dy = (Double(y) - ground) / 6
                if dx * dx + dy * dy < 1 { g.plot(Double(x), Double(y), Pixel(0xFF963C, alpha: 0.13)) }
            }
        }
        if tier == 0 {
            g.rect(fx, ground - 7, 1, 7, Pixel(0xD8B48A))
            g.plot(fx, ground - 8, Pixel(0x9A2C1A))
            return
        }
        for stone in -3...3 {
            let x = fx + Double(stone * 4) - 1
            g.rect(x, ground - 2, 3, 2, Pixel(0x4A4D57))
            g.plot(x, ground - 2, Pixel(0x6D717C))
        }
        g.rect(fx - 8, ground - 4, 16, 2, Pixel(0x5C3A20))
        g.rect(fx - 8, ground - 4, 16, 1, Pixel(0x7A4E2C))
        g.plot(fx - 8, ground - 4, Pixel(0xA07048))
        g.plot(fx + 7, ground - 3, Pixel(0x3A2414))
    }

    private static func animateCamp(_ g: inout PixelBuffer, t: Double, tier: Int, _ palette: PixelPalette) {
        let ground = Double(PixelBuffer.ground)
        switch tier {
        case ..<0: break
        case 0: g.fire(campfire, base: ground - 9, height: 6, width: 1.6, palette, t: t, seed: 1)
        default: g.fire(campfire, base: ground - 4, height: tier == 1 ? 11 : 18, width: tier == 1 ? 3.2 : 5.5, palette, t: t, seed: 1)
        }
    }

    // MARK: The Forge: a village at dusk, a hearth hotter at each tier, an anvil

    private static let houses: [(x: Double, width: Int, height: Double)] = [(6, 22, 16), (30, 18, 12), (290, 20, 14), (314, 22, 18)]
    private static let smithy = 214.0

    private static func forge(_ g: inout PixelBuffer, tier: Int, _ palette: PixelPalette) {
        let ground = Double(PixelBuffer.ground), bx = smithy
        g.sky([0x2A0F2E, 0x45183A, 0x702638, 0xA83E30, 0xD8662E, 0xF2943A])
        g.disc(44, 72, radius: 13) { d, _, _ in Pixel(d > 0.85 ? 0xFFB85A : 0xFFD88A) }
        g.ridge(seed: 4, base: 72, amplitude: 8, 0x3A1A24)
        for (x, w, h) in houses {
            g.rect(x, ground - h, Double(w), h, Pixel(0x1C1018))
            for j in 0..<(w / 2) { g.rect(x + Double(j), ground - h - Double(j) * 0.6, Double(w - j * 2), 1, Pixel(0x26141C)) }
        }
        g.ground(0x1C130F, edge: 0x2C1D14, seed: 2)
        g.rect(bx, 52, 62, 34, Pixel(0x2E211C))
        for y in stride(from: 54, to: PixelBuffer.ground, by: 4) {
            for x in stride(from: Int(bx) + (y / 4) % 2 * 4, to: Int(bx) + 62, by: 8) { g.rect(Double(x), Double(y), 7, 1, Pixel(0x3A2A22)) }
        }
        for j in 0..<10 { g.rect(bx - 4 + Double(j * 2), Double(52 - j), Double(70 - j * 4), 1, Pixel(j % 2 == 1 ? 0x3C2A24 : 0x46322A)) }
        g.rect(bx + 46, 30, 9, 16, Pixel(0x3A2A22))
        g.rect(bx + 45, 29, 11, 2, Pixel(0x4A362C))
        g.rect(bx + 12, 64, 28, 22, Pixel(0x0D0705))
        g.rect(bx + 12, 64, 28, 1, Pixel(0x4A2A1A))
        let ax = 160.0
        g.rect(ax - 9, 76, 20, 3, Pixel(0x4A4C58))
        g.rect(ax - 9, 76, 20, 1, Pixel(0x6C6F7C))
        g.rect(ax - 12, 77, 4, 2, Pixel(0x4A4C58))
        g.rect(ax - 4, 79, 10, 4, Pixel(0x33353F))
        g.rect(ax - 7, 83, 16, 3, Pixel(0x2A2C34))
        g.rect(ax - 5, 75, 9, 1, palette.inner)
        g.rect(ax - 4, 75, 6, 1, palette.core)
    }

    private static func animateForge(_ g: inout PixelBuffer, t: Double, tier: Int, _ palette: PixelPalette) {
        let ground = Double(PixelBuffer.ground), bx = smithy
        for (x, _, h) in houses { g.rect(x + 4, ground - h + 4, 3, 3, Pixel(sin(t * 3 + x) > -0.6 ? 0xFFC65A : 0xA8642A)) }
        for puff in 0..<7 {
            let age = (t * 0.28 + Double(puff) / 7).truncatingRemainder(dividingBy: 1)
            g.rect(bx + 48 + sin(t + Double(puff)) * 3 + age * 6, 26 - age * 26, 4, 3, Pixel(0x6E5A60, alpha: 0.55 - age * 0.55))
        }
        g.fire(bx + 26, base: ground - 1, height: 9 + (tier - 3) * 3, width: 7, palette, t: t, seed: 2)
        for x in stride(from: Int(bx) + 13, to: Int(bx) + 40, by: 2) {
            g.plot(Double(x), Double(64 + x % 3), Pixel(0xFFAA50, alpha: 0.15 + 0.1 * sin(t * 8 + Double(x))))
        }
    }

    // MARK: Launch: dawn at the pad; at Rocket Fuel the rocket lifts off, again and again

    private static func launch(_ g: inout PixelBuffer, stars: Int) {
        let ground = Double(PixelBuffer.ground), width = Double(PixelBuffer.width)
        g.sky([0x0A1640, 0x16286A, 0x2C4A9A, 0x5A7AC8, 0xA4B4E0, 0xF0C8B0])
        g.stars(count: stars)
        g.ridge(seed: 5, base: 78, amplitude: 4, 0x3A4A7A)
        g.ground(0x20242E, edge: 0x3A4050, seed: 3)
        g.rect(0, ground, width, 1, Pixel(0x454C5E))
        for x in stride(from: 232, to: 300, by: 6) { g.rect(Double(x), ground, 3, 1, Pixel(0xD9B84A)) }
        let gx = 244.0
        g.rect(gx, 26, 3, 60, Pixel(0x4A5060))
        g.rect(gx + 9, 26, 3, 60, Pixel(0x3A4050))
        for y in stride(from: 28, to: PixelBuffer.ground, by: 6) { g.line(gx, Double(y), gx + 11, Double(y + 5), Pixel(0x4A5060)) }
    }

    private static func animateLaunch(_ g: inout PixelBuffer, t: Double, tier: Int, _ palette: PixelPalette) {
        let ground = Double(PixelBuffer.ground), width = Double(PixelBuffer.width)
        for (index, (x, y)) in [(20.0, 22.0), (120, 14), (210, 26), (300, 18)].enumerated() {
            let dx = (x + t * 3 * Double(1 + index % 2)).truncatingRemainder(dividingBy: width + 60) - 30
            g.rect(dx, y, 30, 4, Pixel(0xFFFFFF, alpha: 0.5))
            g.rect(dx + 6, y - 3, 16, 3, Pixel(0xFFFFFF, alpha: 0.5))
            g.rect(dx + 2, y + 4, 26, 1, Pixel(0xC8D2F0, alpha: 0.4))
        }
        let cycle = t.truncatingRemainder(dividingBy: 7), firing = tier == 8 && cycle > 1.4
        let lift = tier == 8 ? pow(max(0, cycle - 2), 2) * 3.2 : 0, rx = 272.0, ry = 40 - lift
        if ry > -60 {
            g.rect(rx - 5, ry, 10, 36, Pixel(0xE9EBF2))
            g.rect(rx + 2, ry, 3, 36, Pixel(0xC2C6D2))
            g.rect(rx - 5, ry, 1, 36, .white)
            for j in 0..<10 {
                let w = Double(min(10, 2 + j))
                g.rect(rx - w / 2, ry - 10 + Double(j), w, 1, j < 4 ? palette.body : Pixel(0xE9EBF2))
            }
            g.rect(rx - 2, ry + 8, 4, 4, Pixel(0x2B3550))
            g.plot(rx - 1, ry + 9, Pixel(0x9FD8FF))
            g.rect(rx - 5, ry + 22, 10, 2, palette.body)
            for j in 0..<8 {
                g.rect(rx - 6 - Double(j >> 1), ry + 28 + Double(j), Double(1 + j >> 1), 1, palette.shade)
                g.rect(rx + 5, ry + 28 + Double(j), Double(1 + j >> 1), 1, palette.shade)
            }
            g.rect(rx - 3, ry + 36, 6, 2, Pixel(0x3A3F4C))
            if firing {
                g.exhaust(rx, top: ry + 38, length: Int(max(5, min(14 + lift, ground + 4 - (ry + 38)))), width: 3.2, palette,
                          t: t, seed: 5)
            }
        }
        if firing {
            for puff in 0..<26 {
                let age = (t * 1.5 + Double(puff) * 0.37).truncatingRemainder(dividingBy: 1)
                g.rect(rx + sin(Double(puff) * 2.3) * (6 + age * 26), ground - 2 - age * 6, 3, 2, Pixel(0xDCE0EA, alpha: 0.7 - age * 0.6))
            }
        } else if sin(t * 1.3) > 0.3 {
            for k in 0..<6 { g.plot(rx + 6 + Double(k), ry + 20 - Double(k), Pixel(0xE6EBF5, alpha: 0.6 - Double(k) * 0.1)) }
        }
    }

    // MARK: The Sun: flying through space toward a star that swells red

    private static let sunCentre = (x: 336.0, y: 52.0)

    private static func sunRadius(_ tier: Int) -> Int { tier == 9 ? 40 : 56 }

    private static func sun(_ g: inout PixelBuffer, tier: Int, stars: Int, _ palette: PixelPalette) {
        g.sky([0x020208, 0x04040E, 0x070714, 0x0A0A1A, 0x0D0C1E, 0x100E22])
        g.stars(count: stars)
        g.disc(218, 76, radius: 6) { d, i, j in Pixel(i + j < -3 ? 0x8A7AB8 : d > 0.75 ? 0x3A3060 : 0x5A4C8A) }
        g.disc(sunCentre.x, sunCentre.y, radius: sunRadius(tier)) { d, _, _ in
            d < 0.5 ? palette.core : d < 0.78 ? palette.inner : d < 0.93 ? palette.body : palette.shade
        }
    }

    private static func animateSun(_ g: inout PixelBuffer, t: Double, tier: Int, _ palette: PixelPalette) {
        let width = Double(PixelBuffer.width), radius = sunRadius(tier), r = Double(radius), (cx, cy) = sunCentre
        for k in 0..<10 {
            let x = width - (t * 70 + Double(k * 53)).truncatingRemainder(dividingBy: width + 30)
            g.rect(x, Double(k * 37 % 92 + 4), 5, 1, Pixel(0xFFFFFF, alpha: 0.28))
        }
        // The corona: a dithered, rippling rim just outside the disc.
        for y in (-radius - 9)...(radius + 9) {
            for x in (-radius - 9)...0 where (x + y) % 2 != 0 {
                let d = Double(x * x + y * y).squareRoot()
                if d >= r, d < r + 4 + sin(atan2(Double(y), Double(x)) * 9 + t * 2) * 3 {
                    g.plot(cx + Double(x), cy + Double(y), palette.body)
                }
            }
        }
        for flare in 0..<3 {
            let angle = .pi - 0.7 + Double(flare) * 0.6 + sin(t + Double(flare)) * 0.1
            for step in 0..<18 {
                let reach = r + Double(step)
                g.plot(cx + cos(angle) * reach + sin(Double(step) * 0.5 + t * 3) * 2, cy + sin(angle) * reach,
                       step % 2 == 1 ? palette.inner : palette.body)
            }
        }
    }

    // MARK: Cosmos: a nebula that bursts, pulses, then begins again

    private static let nebula = (x: 236.0, y: 48.0)

    private static func cosmos(_ g: inout PixelBuffer, stars: Int) {
        g.sky([0x05020C, 0x0B0418, 0x140726, 0x1C0A30, 0x14082A, 0x0A0418])
        let (cx, cy) = nebula
        for mote in 0..<700 {
            let angle = scatter(mote, 31) * 2 * .pi, distance = scatter(mote, 32) * 60
            g.plot(cx + cos(angle + distance * 0.05) * distance * 1.7, cy + sin(angle + distance * 0.05) * distance * 0.6,
                   mote % 3 == 0 ? Pixel(0xFF5AA0, alpha: 0.2) : Pixel(0xA050FF, alpha: 0.22))
        }
        g.stars(count: stars)
    }

    private static func animateCosmos(_ g: inout PixelBuffer, t: Double, tier: Int, _ palette: PixelPalette) {
        let (cx, cy) = nebula
        switch tier {
        case 11:
            for ring in 0..<2 {
                let phase = (t * 0.5 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1), reach = 6 + phase * 48
                for angle in stride(from: 0.0, to: 6.28, by: 0.06) where sin(angle * 7 + t) > -0.2 {
                    g.plot(cx + cos(angle) * reach, cy + sin(angle) * reach * 0.8, phase < 0.5 ? palette.inner : palette.body)
                }
            }
        case 12:
            let angle = t * 2
            for step in 6..<90 {
                for direction in [1.0, -1.0] {
                    let x = cx + cos(angle) * Double(step) * direction, y = cy + sin(angle) * Double(step) * direction
                    g.plot(x, y, step % 3 == 0 ? palette.core : palette.inner)
                    g.plot(x, y + 1, Pixel(0xA0E6FF, alpha: 0.3))
                }
            }
        case 13:
            let phase = (t * 0.4).truncatingRemainder(dividingBy: 1)
            for mote in 0..<160 {
                let angle = Double(mote) / 160 * 6.28, distance = 4 + phase * 100 * (0.6 + Double(mote % 7) / 14)
                g.plot(cx + cos(angle) * distance, cy + sin(angle) * distance * 0.7,
                       hsl(hue: (Double(mote * 3) + t * 120).truncatingRemainder(dividingBy: 360), saturation: 0.9, lightness: 0.7))
            }
        default: break
        }
        g.disc(cx, cy, radius: 6) { d, _, _ in d < 0.45 ? palette.core : d < 0.8 ? palette.inner : palette.body }
    }

    private static func hsl(hue: Double, saturation: Double, lightness: Double) -> Pixel {
        let a = saturation * min(lightness, 1 - lightness)
        let channel = { (n: Double) -> UInt32 in
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            return UInt32(((lightness - a * max(-1, min(k - 3, 9 - k, 1))) * 255).rounded())
        }
        return Pixel(channel(0) << 16 | channel(8) << 8 | channel(4))
    }
}

/// Bot-7, the story's hero: a 22 × 30 sprite lit from the left, whose eyes,
/// chest and antenna take the tier's colours. It gains shoulder plates at
/// the forge, boot thrusters at the launch pad, fins in flight and a halo
/// in the cosmos.
enum BotSeven {
    /// The left half; the right half mirrors it and takes the shadow tones.
    /// o outline · w top light · h rim (lit left, shadowed right) · l plate
    /// m lower plate · k joint · v visor · E/e eye · A/a antenna light
    /// G/C/c chest core · b boot
    static let half = [
        ".........oo", "........oAa", "........oaa", ".........oo", "..........k",
        "....ooooooo", "...owwwwwww", "..ohlllllll", "..ohlvvvvvv", ".kohlvEEvvv", ".kohlveevvv", "..ohlvvvvvv",
        "..ohllllkkk", "..ohmmmmmmm", "...oooooooo",
        "........okk",
        "...oooooooo", "oooohwwwwww", "ohhohllllll", "ohlohlllloo", "ohlohllloGC", "ohlohllloCC", "ohlohlllloo",
        "okkohllllll", "oooohmmmmmm", "...oooooooo",
        "....ohlko..", "....ohlko..", "...obbbbbo.", "...ooooooo.",
    ]

    static let sprite: [[Character]] = half.map { row in
        let mirrored = row.reversed().map { ["h": "H", "l": "L", "w": "W", "A": "a", "G": "C"][$0] ?? $0 }
        return Array(row) + mirrored
    }

    /// Draws Bot-7 centred on `x`, standing on `ground` or hovering above it,
    /// and returns the sprite's top-left corner.
    @discardableResult
    static func draw(_ g: inout PixelBuffer, x: Double, ground: Double, t: Double, chapter: StoryChapter,
                     palette p: PixelPalette, flies: Bool) -> (left: Double, top: Double) {
        let stage = chapter.rawValue, blink = t.truncatingRemainder(dividingBy: 4.2) < 0.12
        let lift = flies ? 22 + (sin(t * 2) * 2).rounded() : stage >= 2 ? 9 + (sin(t * 3) * 1.5).rounded() : 0
        let left = x - 11, top = ground - Double(sprite.count) - lift
        let visor = Pixel(0x0B0E16), antennaOn = sin(t * 4) > 0
        let tones: [Character: Pixel] = [
            "o": Pixel(0x141720), "w": Pixel(0xF4F6FB), "W": Pixel(0xDDE2EA), "h": Pixel(0xE3E7EF), "H": Pixel(0x636A7C),
            "l": Pixel(0xBAC1CE), "L": Pixel(0xA2A9B7), "m": Pixel(0x858D9F), "k": Pixel(0x363B48), "v": visor,
            "E": blink ? visor : p.core, "e": blink ? visor : p.inner,
            "a": antennaOn ? p.body : Pixel(0x4A4F5C), "A": antennaOn ? p.core : Pixel(0x6A707E),
            "c": p.inner, "C": p.inner, "G": p.core, "b": Pixel(stage >= 2 ? 0x5A6070 : 0x474D5C),
        ]
        // Hovering casts a shadow on the ground below.
        if lift > 0, !flies {
            let reach = Int(13 - lift * 0.3), shift = Int(t * 10)
            for i in -reach...reach where (i + shift) % 2 == 0 { g.plot(x + Double(i), ground, Pixel(0x000000, alpha: 0.45)) }
        }
        if stage >= 3 {
            for j in 0..<7 {
                let colour = j < 2 ? p.inner : p.shade, out = j > 3 ? 1.0 : 0
                g.rect(left - 2 - out, top + 18 + Double(j), 2, 1, colour)
                g.rect(left + 22 + out, top + 18 + Double(j), 2, 1, colour)
            }
        }
        for (j, row) in sprite.enumerated() {
            for (i, symbol) in row.enumerated() where symbol != "." {
                if let tone = tones[symbol] { g.plot(left + Double(i), top + Double(j), tone) }
            }
        }
        if stage >= 1 {
            g.rect(left + 1, top + 17, 2, 2, p.body)
            g.rect(left + 19, top + 17, 2, 2, p.shade)
            g.plot(left + 1, top + 17, p.inner)
        }
        if stage >= 2 {
            for (column, width) in [(4.0, 5.0), (13, 5)] {
                g.rect(left + column, top + 30, width, 1, Pixel(0x2B2F3A))
                g.rect(left + column + 1, top + 31, width - 2, 1, Pixel(0x1D2028))
            }
            let length = flies ? 10 + Int((sin(t * 9) * 2).rounded()) : Int(lift) - 1
            g.exhaust(left + 6, top: top + 32, length: length, width: 2.4, p, t: t, seed: 1)
            g.exhaust(left + 15, top: top + 32, length: length, width: 2.4, p, t: t, seed: 2)
            if !flies {
                for k in 0..<6 {
                    let age = (t * 3 + Double(k) / 6).truncatingRemainder(dividingBy: 1)
                    g.plot(x + (k % 2 == 1 ? 1 : -1) * (3 + age * 12), ground - 1 - (age * 2).rounded(.down),
                           Pixel(0xFFDCAA, alpha: 0.6 - age * 0.6))
                }
            }
        }
        if stage >= 4 {
            for angle in stride(from: 0.0, to: 6.28, by: 0.26) { g.plot(x + cos(angle) * 7, top - 3 + sin(angle) * 1.6, p.inner) }
            for k in 0..<12 {
                let angle = t * 1.4 + Double(k) / 12 * 6.28
                g.plot(x + cos(angle) * 17, top + 15 + sin(angle) * 19, k % 3 == 0 ? p.core : p.inner)
            }
        }
        return (left, top)
    }

    /// At the forge Bot-7 swings a hammer at the anvil; sparks fly when it
    /// lands, more of them at The Forge.
    static func hammer(_ g: inout PixelBuffer, left: Double, top: Double, t: Double, _ p: PixelPalette, tier: Int) {
        let phase = (t * 1.3).truncatingRemainder(dividingBy: 1), down = phase > 0.55
        let hx = left + 21, hy = top + 22
        let (ex, ey) = down ? (hx + 18, hy + 9) : (hx + 6, hy - 14)
        g.line(hx, hy, ex, ey, Pixel(0x7A5030))
        if down {
            g.rect(ex - 2, ey - 2, 6, 4, Pixel(0x5A5E6C))
            g.rect(ex - 2, ey - 2, 6, 1, Pixel(0x8A8E9C))
        } else {
            g.rect(ex - 2, ey - 3, 4, 6, Pixel(0x5A5E6C))
            g.rect(ex - 2, ey - 3, 1, 6, Pixel(0x8A8E9C))
        }
        guard down, phase < 0.75 else { return }
        for spark in 0..<(tier >= 5 ? 14 : 7) {
            let angle = -Double.pi / 2 + (scatter(spark, 1, Int(t * 1.3), 3) - 0.5) * 2.6
            let reach = (phase - 0.55) * 5 * (4 + scatter(spark, 2) * 10)
            g.plot(ex + 1 + cos(angle) * reach, ey + sin(angle) * reach, spark % 2 == 1 ? p.core : p.inner)
        }
    }
}
