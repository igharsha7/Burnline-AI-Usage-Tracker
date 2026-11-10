//
//  Medal.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import simd
import SwiftUI

/// A medal's outline, one per shelf, so a medal's shape says what it is for
/// before its face is read.
enum MedalForm {
    /// A ridged coin: Volume.
    case coin
    case shield
    case hexagon
    case octagon
    /// A square on its point.
    case diamond
    /// Eight soft points: Explorer.
    case rosette
    /// A smooth coin: the repeatable awards.
    case disc
    /// A seal with scalloped edges: Monthly Challenges.
    case seal
    /// Twelve sharp rays: Limited Edition.
    case sunburst
    /// A rounded square, like a plaque on a building: Landmarks.
    case plaque

    init(_ category: AchievementCategory) {
        switch category {
        case .volume: self = .coin
        case .landmarks: self = .plaque
        case .streaks: self = .shield
        case .efficiency: self = .hexagon
        case .pacing: self = .octagon
        case .sessions: self = .diamond
        case .explorer: self = .rosette
        case .repeatable: self = .disc
        case .monthly: self = .seal
        case .limited: self = .sunburst
        }
    }
}

/// The outline of a `MedalForm`, filling its frame.
struct MedalShape: Shape {
    let form: MedalForm

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        switch form {
        case .coin: return Self.star(c, r, points: 40, inner: 0.955, smooth: true)
        case .disc: return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .hexagon: return Self.polygon(c, r, sides: 6, rotation: 0, rounding: 0.12)
        case .octagon: return Self.polygon(c, r, sides: 8, rotation: .pi / 8, rounding: 0.1)
        case .diamond: return Self.polygon(c, r, sides: 4, rotation: 0, rounding: 0.16)
        case .rosette: return Self.star(c, r, points: 8, inner: 0.8, smooth: true)
        case .seal: return Self.star(c, r, points: 16, inner: 0.9, smooth: true)
        case .sunburst: return Self.star(c, r, points: 12, inner: 0.8, smooth: false)
        case .plaque:
            return Path(roundedRect: CGRect(x: c.x - r * 0.9, y: c.y - r * 0.9, width: r * 1.8, height: r * 1.8),
                        cornerRadius: r * 0.42, style: .continuous)
        case .shield: return Self.shield(in: rect.insetBy(dx: (rect.width - 2 * r) / 2, dy: (rect.height - 2 * r) / 2))
        }
    }

    /// A regular polygon, its corners rounded by `rounding` of the radius.
    static func polygon(_ c: CGPoint, _ r: CGFloat, sides: Int, rotation: CGFloat, rounding: CGFloat) -> Path {
        let points = (0..<sides).map { i -> CGPoint in
            let a = rotation - .pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        var path = Path()
        let radius = r * rounding
        for i in 0..<sides {
            let previous = points[(i + sides - 1) % sides], current = points[i], next = points[(i + 1) % sides]
            let start = point(current, toward: previous, by: radius), end = point(current, toward: next, by: radius)
            if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addQuadCurve(to: end, control: current)
        }
        path.closeSubpath()
        return path
    }

    /// Points alternating between `r` and `inner × r`; smoothed, a wave.
    static func star(_ c: CGPoint, _ r: CGFloat, points: Int, inner: CGFloat, smooth: Bool) -> Path {
        let count = points * 2
        let vertices = (0..<count).map { i -> CGPoint in
            let a = -.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
            let radius = i.isMultiple(of: 2) ? r : r * inner
            return CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
        }
        var path = Path()
        if smooth {
            // Through the midpoints, with each vertex as a control point.
            let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            path.move(to: mid(vertices[count - 1], vertices[0]))
            for i in 0..<count { path.addQuadCurve(to: mid(vertices[i], vertices[(i + 1) % count]), control: vertices[i]) }
        } else {
            path.move(to: vertices[0])
            for vertex in vertices.dropFirst() { path.addLine(to: vertex) }
        }
        path.closeSubpath()
        return path
    }

    static func shield(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        var path = Path()
        path.move(to: CGPoint(x: x + w * 0.5, y: y))
        path.addCurve(to: CGPoint(x: x + w * 0.95, y: y + h * 0.14),
                      control1: CGPoint(x: x + w * 0.66, y: y + h * 0.08), control2: CGPoint(x: x + w * 0.82, y: y + h * 0.12))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h),
                      control1: CGPoint(x: x + w * 0.98, y: y + h * 0.58), control2: CGPoint(x: x + w * 0.8, y: y + h * 0.84))
        path.addCurve(to: CGPoint(x: x + w * 0.05, y: y + h * 0.14),
                      control1: CGPoint(x: x + w * 0.2, y: y + h * 0.84), control2: CGPoint(x: x + w * 0.02, y: y + h * 0.58))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y),
                      control1: CGPoint(x: x + w * 0.18, y: y + h * 0.12), control2: CGPoint(x: x + w * 0.34, y: y + h * 0.08))
        path.closeSubpath()
        return path
    }

    private static func point(_ from: CGPoint, toward to: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, length = max(hypot(dx, dy), 0.001)
        return CGPoint(x: from.x + dx / length * distance, y: from.y + dy / length * distance)
    }
}

/// A metal's colours, from its highlight to its shadow.
struct MetalPalette {
    let highlight: Color
    let light: Color
    let mid: Color
    let dark: Color
    /// The engraving on the face: darker than the face, lit from above.
    let engraving: Color
    let glow: Color?

    init(_ highlight: UInt32, _ light: UInt32, _ mid: UInt32, _ dark: UInt32, engraving: UInt32, glow: UInt32? = nil) {
        self.highlight = Color(hex: highlight)
        self.light = Color(hex: light)
        self.mid = Color(hex: mid)
        self.dark = Color(hex: dark)
        self.engraving = Color(hex: engraving)
        self.glow = glow.map { Color(hex: $0) }
    }

    /// The metal's colours, or for an earned monthly medal its birthstone's.
    static func of(_ metal: Metal?, stone: Int? = nil) -> MetalPalette {
        if metal != nil, let stone, let palette = birthstone(stone) { return palette }
        return switch metal {
        case .bronze: MetalPalette(0xFFE1C2, 0xE2A06A, 0xB46F3C, 0x5E3418, engraving: 0x6B3B1C)
        case .silver: MetalPalette(0xFFFFFF, 0xE4E8ED, 0xAEB6BF, 0x5C636C, engraving: 0x59606A)
        case .gold: MetalPalette(0xFFF6CF, 0xFFD86B, 0xD9A21E, 0x7A520A, engraving: 0x7D560C)
        case .platinum: MetalPalette(0xF4FAFC, 0xD3E3EA, 0x93AEB9, 0x435966, engraving: 0x3F5562)
        case .diamond: MetalPalette(0xF2FDFF, 0xAEEBFA, 0x4FB9E0, 0x14567A, engraving: 0x125074, glow: 0x7FD8F5)
        case .ember: MetalPalette(0xFFF0C9, 0xFFB35C, 0xF2591D, 0x6E1C08, engraving: 0x701E08, glow: 0xFF7A33)
        case nil: MetalPalette(0x6A6F76, 0x44484E, 0x2E3136, 0x17191C, engraving: 0x121416)
        }
    }

    /// Each month's birthstone, January's garnet to December's turquoise.
    /// Stones catch the light, so each gives off a little of its colour.
    static func birthstone(_ month: Int) -> MetalPalette? {
        switch month {
        case 1: MetalPalette(0xFFD3D3, 0xE0525E, 0x9E1B2C, 0x4A0710, engraving: 0x4A0A14, glow: 0xE0525E)
        case 2: MetalPalette(0xF3E2FF, 0xB98AE6, 0x7B48B5, 0x36175C, engraving: 0x34175A, glow: 0xB98AE6)
        case 3: MetalPalette(0xEFFFFC, 0x9FE6DF, 0x4DB6B0, 0x1B5A5A, engraving: 0x174F50, glow: 0x7FD6CF)
        case 4: MetalPalette(0xFFFFFF, 0xEEF4FA, 0xBCCAD8, 0x5E6B7A, engraving: 0x4F5B69, glow: 0xDCE8F5)
        case 5: MetalPalette(0xDFFFE9, 0x5ED18C, 0x1E8E4E, 0x0A3D20, engraving: 0x0B3A1F, glow: 0x4CC27E)
        case 6: MetalPalette(0xFFFFFF, 0xF4EEE6, 0xD8CCBE, 0x7A6E62, engraving: 0x6D6156, glow: 0xEFE4D6)
        case 7: MetalPalette(0xFFD6DC, 0xF04462, 0xB0102F, 0x50040F, engraving: 0x52061A, glow: 0xF04462)
        case 8: MetalPalette(0xF6FFD6, 0xC4E35A, 0x86A920, 0x3B4D08, engraving: 0x3A4A09, glow: 0xB4D646)
        case 9: MetalPalette(0xDCE8FF, 0x5C8DEB, 0x1D47B0, 0x0A1D55, engraving: 0x0B1F57, glow: 0x5C8DEB)
        case 10: MetalPalette(0xFFE0EE, 0xF27BB0, 0xC23B7B, 0x5A1236, engraving: 0x5A1438, glow: 0xF27BB0)
        case 11: MetalPalette(0xFFF1D6, 0xFFC25C, 0xE08A12, 0x6E3D04, engraving: 0x6B3B06, glow: 0xFFB13D)
        case 12: MetalPalette(0xE0FFFB, 0x6FDCD3, 0x1FA8A6, 0x0A4F52, engraving: 0x0B4A4D, glow: 0x4FCBC4)
        default: nil
        }
    }

    /// The stone's name, for a monthly medal's line.
    static func stoneName(_ month: Int) -> String? {
        let names = ["Garnet", "Amethyst", "Aquamarine", "Diamond", "Emerald", "Pearl", "Ruby", "Peridot",
                     "Sapphire", "Tourmaline", "Topaz", "Turquoise"]
        return names.indices.contains(month - 1) ? names[month - 1] : nil
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// What a medal shows on its face.
struct MedalFace: Equatable {
    let symbol: String
    /// A figure engraved under the symbol: "1B", "30", "$1K", "NOV".
    let label: String?
    /// A ladder rung's grade, struck as a numeral on a tab at the foot.
    var grade: Int?
    /// The birth month whose stone a monthly medal is set in.
    var stone: Int?
    /// A landmark drawn on the face in place of the symbol.
    var landmark: Landmark.Silhouette?

    init(symbol: String, label: String? = nil, grade: Int? = nil, stone: Int? = nil,
         landmark: Landmark.Silhouette? = nil) {
        self.symbol = symbol
        self.label = label
        self.grade = grade
        self.stone = stone
        self.landmark = landmark
    }

    init(_ badge: AchievementBadge, tier: String? = nil) {
        self.init(kind: badge.kind, badge: badge, tier: tier)
        grade = badge.grade
        stone = badge.stone
    }

    private init(kind: AchievementKind, badge: AchievementBadge, tier: String?) {
        let threshold = badge.threshold.map(AchievementFace.compact)
        switch kind {
        case .lifetimeTokens: self.init(symbol: "flame.fill", label: threshold)
        case .odometer: self.init(symbol: "gauge.open.with.lines.needle.33percent")
        case .landmark:
            let landmark = Landmark.all.first { String($0.tokens) == badge.tier }
            self.init(symbol: "building.2.fill", label: landmark.map { AchievementFace.height($0.meters) },
                      landmark: landmark?.silhouette)
        case .restDay: self.init(symbol: "bed.double.fill")
        case .cacheMaster:
            self.init(symbol: "bolt.circle.fill", label: badge.threshold.map(AchievementFace.span))
        case .leapDay: self.init(symbol: "hare.fill")
        case .midnightCrossing: self.init(symbol: "party.popper.fill")
        case .deepDive: self.init(symbol: "scope", label: threshold)
        case .projectHopper: self.init(symbol: "folder.fill.badge.plus", label: threshold)
        case .modelHopper: self.init(symbol: "cpu", label: String(Achievement.modelHopperCount))
        case .comeback: self.init(symbol: "arrow.uturn.backward", label: threshold.map { "\($0)D" })
        case .aroundTheClock: self.init(symbol: "clock.fill")
        case .sevenDays: self.init(symbol: "calendar.badge.checkmark")
        case .oldFriend: self.init(symbol: "person.2.fill")
        case .foundingYear: self.init(symbol: "building.columns.fill", label: badge.tier)
        case .streak: self.init(symbol: "calendar", label: threshold)
        case .freezeUsed: self.init(symbol: "snowflake")
        case .cacheSavings: self.init(symbol: "arrow.triangle.2.circlepath", label: threshold.map { "$\($0)" })
        case .steadyHand: self.init(symbol: "gauge.with.dots.needle.33percent", label: threshold.map { "\($0)W" })
        case .sessions: self.init(symbol: "square.stack.3d.up.fill", label: threshold)
        case .nightOwl: self.init(symbol: "moon.stars.fill")
        case .earlyBird: self.init(symbol: "sunrise.fill")
        case .marathon: self.init(symbol: "figure.run")
        case .firstSession: self.init(symbol: "sparkle")
        case .providersInADay: self.init(symbol: "square.split.2x1.fill", label: badge.tier)
        case .models: self.init(symbol: "cpu.fill", label: threshold)
        case .projects: self.init(symbol: "folder.fill", label: threshold)
        case .perfectWeek: self.init(symbol: "checkmark.seal.fill")
        case .hotCache: self.init(symbol: "bolt.fill")
        case .underTheLine: self.init(symbol: "gauge.with.needle.fill")
        case .monthly:
            let tier = tier ?? badge.tier
            self.init(symbol: tier.flatMap { MonthlyChallenge.schedule[$0] }.map(AchievementFace.symbol) ?? "flag.checkered",
                      label: tier.flatMap(AchievementFace.month))
        case .alphaTester: self.init(symbol: "flask.fill")
        case .anniversary: self.init(symbol: "birthday.cake.fill")
        case .yearOfBuilding: self.init(symbol: "hammer.fill", label: tier)
        }
    }
}

enum AchievementFace {
    static func compact(_ value: Int64) -> String { AchievementBadge.compact(value) }

    /// 330 as "330m", 8,849 as "8.8km", 408,000 as "408km": short enough
    /// for a face, and lower case so a height never reads as a count.
    static func height(_ meters: Double) -> String {
        switch meters {
        case ..<1_000: "\(Int(meters))m"
        case ..<10_000: "\((meters / 1_000).formatted(.number.precision(.fractionLength(1))))km"
        default: "\(Int(meters / 1_000))km"
        }
    }

    /// A Cache Master rung on a face: "1W", "6MO", "1Y", "18MO".
    static func span(_ days: Int64) -> String {
        let months = AchievementBadge.cacheMasterMonths(days)
        return months == 0 ? "1W" : months.isMultiple(of: 12) ? "\(months / 12)Y" : "\(months)MO"
    }

    static func symbol(_ challenge: MonthlyChallenge.Kind) -> String {
        switch challenge {
        case .underTheLimit: "gauge.with.needle.fill"
        case .cacheKeeper: "bolt.fill"
        case .showingUp: "calendar"
        case .lightsOut: "moon.zzz.fill"
        case .newGround: "map.fill"
        case .steadyWeeks: "gauge.with.dots.needle.33percent"
        case .deepFocus: "scope"
        case .betterCache: "arrow.up.right"
        case .weekendsOff: "sun.max.fill"
        case .spreadOut: "calendar.day.timeline.left"
        case .rested: "bed.double.fill"
        case .fullRoster: "square.grid.2x2.fill"
        case .oneThingWell: "target"
        case .calmLimits: "leaf.fill"
        }
    }

    /// "2026-11" as "NOV".
    static func month(_ tier: String) -> String? {
        guard let month = Int(tier.split(separator: "-").last ?? ""), (1...12).contains(month) else { return nil }
        return AchievementText.calendar.shortMonthSymbols[month - 1].uppercased()
    }
}

/// Medals drawn at rest, shared by every view of the same medal. Bounded
/// by bytes, so a long scroll through the shelves never grows it unchecked.
@MainActor
enum MedalImages {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
}

/// One medal: a rim, a bevel and a recessed, domed face in its metal, the
/// face's symbol and figure engraved, a highlight, and a sheen that crosses
/// it on `shine`. Unearned, it is cast in dark iron with its face dimmed, or
/// a question mark for a secret.
///
/// At rest, untilted and unshone, a medal is drawn once into an image and
/// kept in `MedalImages`, so a lazy grid that rebuilds tiles as they scroll
/// back in only places a bitmap. While the pointer leans on it or the sheen
/// crosses it, it is drawn live into one Metal texture.
struct MedalView: View {
    let form: MedalForm
    let metal: Metal?
    let face: MedalFace
    var size: CGFloat = 84
    var secret = false
    /// The sheen's position across the face, 0 before it and 1 past it.
    var shine: CGFloat = -1
    /// Where the medal has turned, -1 to 1 on each axis; the highlight and
    /// the rim's bright band move against it, as under a fixed light.
    var light: CGSize = .zero
    /// Art for a solid medal's face: no painted highlight or shadow, since
    /// the solid is lit for real, and no cached texture of its own.
    var flat = false

    @Environment(\.displayScale) private var displayScale

    /// Room for the shadow, and an ember or diamond glow, which spreads about
    /// twice its radius: clipped, it would show the texture's square.
    private var bleed: CGFloat { size * 0.3 }

    private var atRest: Bool { !flat && light == .zero && !(shine > -0.5 && shine < 1.5) }

    var body: some View {
        Group {
            if atRest, let image = restingImage() {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size + 2 * bleed, height: size + 2 * bleed)
            } else {
                art.drawingGroup()
            }
        }
        // The bleed given back to layout.
        .padding(-bleed)
        .accessibilityHidden(true)
    }

    /// The medal at rest, from the cache or drawn into it now.
    private func restingImage() -> NSImage? {
        let key = "\(form)|\(String(describing: metal))|\(face)|\(size)|\(secret)|\(displayScale)" as NSString
        if let image = MedalImages.cache.object(forKey: key) { return image }
        let renderer = ImageRenderer(content: art.environment(\.colorScheme, .dark))
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return nil }
        let side = Int((size + 2 * bleed) * displayScale)
        MedalImages.cache.setObject(image, forKey: key, cost: side * side * 4)
        return image
    }

    /// The medal drawn, with its bleed around it.
    private var art: some View {
        let palette = MetalPalette.of(metal, stone: face.stone)
        let shape = MedalShape(form: form)
        let earned = metal != nil
        return ZStack {
            // Rim: the metal turning around the edge.
            shape.fill(AngularGradient(colors: [palette.light, palette.mid, palette.dark, palette.mid,
                                                palette.highlight, palette.mid, palette.dark, palette.light],
                                       center: .center, angle: .degrees(-35 + light.width * 70)))
            // Bevel: lit from below, so the face reads as raised.
            shape.fill(LinearGradient(colors: [palette.dark, palette.mid, palette.light],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(size * 0.055)
            // Face: a dome sunk into the rim, brightest toward the light.
            shape.fill(RadialGradient(colors: [palette.light, palette.mid, palette.dark],
                                      center: UnitPoint(x: 0.35 - light.width * 0.2, y: 0.28 - light.height * 0.15),
                                      startRadius: 0, endRadius: size * 0.75)
                .shadow(.inner(color: .black.opacity(earned ? 0.45 : 0.6), radius: size * 0.025, y: size * 0.018)))
                .padding(size * 0.095)
            // An engraved ring inside the face.
            shape.stroke(palette.dark.opacity(0.55), lineWidth: max(0.75, size * 0.012))
                .padding(size * 0.15)
                .offset(y: size * 0.006)
            shape.stroke(palette.highlight.opacity(0.45), lineWidth: max(0.5, size * 0.008))
                .padding(size * 0.15)
            content(palette, earned: earned)
            if let grade = face.grade, size >= Self.gradeMinimumSize, !(secret && !earned) {
                gradeTab(grade, palette, earned: earned).offset(y: size * Self.gradeDrop)
            }
            // Highlight: a soft reflection where the light falls.
            if !flat {
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(earned ? 0.4 : 0.09), .white.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: size * 0.3))
                .frame(width: size * 0.7, height: size * 0.42)
                .rotationEffect(.degrees(-30))
                .offset(x: -size * (0.14 + light.width * 0.22), y: -size * (0.22 + light.height * 0.14))
                .mask(shape)
            }
            if earned, shine > -0.5, shine < 1.5 {
                LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: size * 0.35)
                    .rotationEffect(.degrees(20))
                    .offset(x: (shine - 0.5) * size * 1.6)
                    .mask(shape)
                    .blendMode(.plusLighter)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: (palette.glow ?? .black).opacity(flat ? 0 : palette.glow == nil ? 0.45 : 0.55),
                radius: size * (palette.glow == nil ? 0.05 : 0.12), y: size * 0.03)
        .padding(bleed)
    }

    /// Below this size the grade's numeral would be too small to read, so
    /// the tab is left off.
    static let gradeMinimumSize: CGFloat = 44
    /// How far below the middle the tab sits: on the rim, but clear of the
    /// outline, where the solid medal trims its printed face.
    static let gradeDrop: CGFloat = 0.355

    /// The grade, struck on a tab that sits across the foot of the rim: a
    /// roman numeral, I to III, raised in the metal's brightest tone on a
    /// plate of its darkest, so it reads at a glance at any size it shows.
    private func gradeTab(_ grade: Int, _ palette: MetalPalette, earned: Bool) -> some View {
        let plate = LinearGradient(colors: [palette.mid, palette.dark], startPoint: .top, endPoint: .bottom)
        let edge: CGFloat = max(0.75, size * 0.014)
        let lift: CGFloat = max(0.5, size * 0.008)
        let numeral = Text(Metal.numeral(grade))
            .font(.system(size: size * 0.13, weight: .black, design: .serif))
            .tracking(size * 0.006)
            .foregroundStyle(palette.highlight)
            .shadow(color: .black.opacity(0.5), radius: 0, y: lift)
        return numeral
            .padding(.horizontal, size * 0.075)
            .padding(.vertical, size * 0.012)
            .background(Capsule().fill(plate))
            .overlay(Capsule().strokeBorder(palette.light.opacity(0.85), lineWidth: edge))
            .shadow(color: .black.opacity(0.4), radius: size * 0.02, y: size * 0.012)
            .opacity(earned ? 1 : 0.7)
    }

    @ViewBuilder
    private func content(_ palette: MetalPalette, earned: Bool) -> some View {
        let symbol = secret && !earned ? "questionmark" : face.symbol
        let label = secret && !earned ? nil : face.label
        // Cut into the face: shadowed along its top edge, inside the cut.
        let emboss = palette.engraving.shadow(.inner(color: .black.opacity(0.55), radius: max(0.5, size * 0.008),
                                                     y: max(0.5, size * 0.01)))
        VStack(spacing: size * 0.01) {
            if let landmark = face.landmark, !(secret && !earned) {
                LandmarkArt(silhouette: landmark)
                    .fill(emboss)
                    .aspectRatio(LandmarkArt.aspect(landmark), contentMode: .fit)
                    .frame(maxWidth: size * 0.52, maxHeight: size * (label == nil ? 0.42 : 0.33))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * (label == nil ? 0.32 : 0.2), weight: .semibold))
            }
            if let label {
                Text(label)
                    .font(.system(size: size * (label.count > 3 ? 0.17 : 0.21), weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .frame(maxWidth: size * 0.6)
            }
        }
        .foregroundStyle(emboss)
        // Lit from above: a bright edge below the engraving, a dark one above.
        .shadow(color: palette.highlight.opacity(earned ? 0.7 : 0.15), radius: 0, y: max(0.5, size * 0.01))
        .opacity(earned ? 1 : 0.55)
    }
}

/// The medal's back, engraved with what it is and when it was earned. Drawn
/// mirrored, so it reads the right way round once the medal has turned.
struct MedalBack: View {
    let form: MedalForm
    let metal: Metal?
    let title: String
    let date: String?
    /// Who it was awarded to, when the user has given a name.
    var name: String? = nil
    var size: CGFloat = 220
    /// Drawn mirrored for a flat medal turned over; a solid one's back is
    /// printed the right way round.
    var mirrored = true
    /// The birthstone a monthly medal is set in.
    var stone: Int? = nil

    var body: some View {
        let palette = MetalPalette.of(metal, stone: stone)
        let shape = MedalShape(form: form)
        ZStack {
            shape.fill(AngularGradient(colors: [palette.mid, palette.dark, palette.mid, palette.light, palette.mid],
                                       center: .center))
            shape.fill(LinearGradient(colors: [palette.mid, palette.dark], startPoint: .top, endPoint: .bottom))
                .padding(size * 0.06)
            VStack(spacing: size * 0.03) {
                Image(systemName: "flame.fill").font(.system(size: size * 0.1))
                Text(title)
                    .font(.system(size: size * 0.07, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                if let date {
                    Text(date).font(.system(size: size * 0.055, weight: .medium, design: .rounded))
                }
                if let name {
                    VStack(spacing: size * 0.005) {
                        Text("AWARDED TO").font(.system(size: size * 0.036, weight: .bold)).tracking(size * 0.006)
                            .opacity(0.75)
                        Text(name).font(.system(size: size * 0.065, weight: .semibold, design: .serif).italic())
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .padding(.top, size * 0.01)
                }
                Text("BURNLINE").font(.system(size: size * 0.045, weight: .heavy)).tracking(size * 0.01)
            }
            .foregroundStyle(palette.light.opacity(0.85))
            .shadow(color: palette.dark, radius: 0, y: -1)
            .frame(maxWidth: size * 0.62)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: mirrored ? -1 : 1)
    }
}

/// A medal held up to look at. Dragged sideways it turns over, carrying a
/// flick's momentum and settling face up with a tap on the trackpad; dragged
/// up or down it tips and springs back level. It spins twice as it opens, an
/// earned medal throws a few sparks and catches the light, and the pointer
/// resting over it leans it gently toward itself.
struct SpinningMedal: View {
    let form: MedalForm
    let metal: Metal?
    let face: MedalFace
    let title: String
    let date: String?
    var secret = false
    /// Engraved on the back, when the user has given one.
    var name: String?
    var size: CGFloat = 220

    /// Turn about the vertical axis, in degrees; a multiple of 360 is face up.
    @State private var yaw: Double = 0
    @State private var yawAtRest: Double = 0
    /// Tip about the horizontal axis, in degrees, springing back to level.
    @State private var pitch: Double = 0
    /// The pointer's lean, -1 to 1 on each axis, while it rests over the medal.
    @State private var lean = CGSize.zero
    @State private var dragging = false
    @State private var shine: CGFloat = -1
    @State private var struck = false
    @State private var burst: CGFloat = 0
    @State private var settles = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Degrees of turn per point dragged sideways, and of tip per point dragged up.
    private static let turnPerPoint = 0.9
    private static let tipPerPoint = 0.6
    /// How far a drag can tip the medal, and how far the pointer leans it.
    private static let maxTip = 50.0
    private static let maxLean = 10.0

    var body: some View {
        let earned = metal != nil
        ZStack {
            if earned {
                SparkBurst(color: MetalPalette.of(metal, stone: face.stone).light, radius: size * 0.62, progress: burst)
            }
            let turn = yaw + lean.width * Self.maxLean, tip = pitch - lean.height * Self.maxLean
            FloorShadow(yaw: turn, width: size * 0.85)
                .offset(y: size * 0.6)
            if let glow = MetalPalette.of(metal, stone: face.stone).glow {
                // Ember and diamond give off light of their own.
                Circle()
                    .fill(RadialGradient(colors: [glow.opacity(0.45), glow.opacity(0)], center: .center,
                                         startRadius: size * 0.3, endRadius: size * 0.62))
                    .frame(width: size * 1.24, height: size * 1.24)
            }
            MedalScene(form: form, metal: metal, face: face, title: title, date: date, secret: secret, name: name,
                       yaw: turn, pitch: tip)
                .frame(width: size / MedalModel.fill, height: size / MedalModel.fill)
                .allowsHitTesting(false)
            if earned, shine > -0.5, shine < 1.5 {
                // A glint crossing the medal as it lands.
                LinearGradient(colors: [.clear, .white.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: size * 0.3, height: size)
                    .rotationEffect(.degrees(20))
                    .offset(x: (shine - 0.5) * size * 1.4)
                    .mask(MedalShape(form: form).frame(width: size, height: size))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size * 1.35, height: size * 1.25)
        .contentShape(Rectangle())
        .scaleEffect(struck || reduceMotion ? 1 : 0.6)
        .onContinuousHover { phase in
            guard !dragging, !reduceMotion else { return }
            let side = size * 1.3
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
                switch phase {
                case .active(let point):
                    lean = CGSize(width: max(-1, min(1, point.x / side * 2 - 1)),
                                  height: max(-1, min(1, point.y / side * 2 - 1)))
                case .ended: lean = .zero
                }
            }
        }
        .gesture(earned ? turning : nil)
        .sensoryFeedback(.alignment, trigger: settles)
        .onAppear(perform: strike)
        .help(earned ? "Drag to turn it over" : "")
    }

    private var turning: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    withAnimation(.spring(response: 0.3, dampingFraction: 1)) { lean = .zero }
                }
                yaw = yawAtRest + value.translation.width * Self.turnPerPoint
                // Resists more the further it tips, as if held on a pin.
                pitch = Self.maxTip * tanh(-value.translation.height * Self.tipPerPoint / Self.maxTip)
            }
            .onEnded { value in
                dragging = false
                // Carry the flick on, then come to rest face up.
                let carried = yawAtRest + value.predictedEndTranslation.width * Self.turnPerPoint
                let rest = (carried / 360).rounded() * 360
                withAnimation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.72)) {
                    yaw = rest
                    pitch = 0
                }
                if rest != yawAtRest { settles += 1 }
                yawAtRest = rest
            }
    }

    /// Turns the medal makes as it opens, and how long they take: two
    /// turns, quick at first and slowing to rest face up, as a medal does
    /// when it is shown off.
    private static let openingTurns = 2.0
    private static let openingSeconds = 1.6

    /// Spins the medal in, then, if it is earned, sparks and a sheen.
    private func strike() {
        guard !reduceMotion else { struck = true; return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { struck = true }
        // Fast out of the gate, a long glide to a stop, with no overshoot.
        withAnimation(.timingCurve(0.2, 0.75, 0.25, 1, duration: Self.openingSeconds)) {
            yaw = 360 * Self.openingTurns
        }
        yawAtRest = 360 * Self.openingTurns
        guard metal != nil else { return }
        withAnimation(.easeOut(duration: 0.9).delay(Self.openingSeconds * 0.6)) { burst = 1 }
        withAnimation(.easeInOut(duration: 1.1).delay(Self.openingSeconds * 0.8)) { shine = 2 }
    }
}

/// The medal's shadow on the floor below it, narrowing as it turns edge on.
private struct FloorShadow: View, Animatable {
    var yaw: Double
    let width: CGFloat

    var animatableData: Double {
        get { yaw }
        set { yaw = newValue }
    }

    var body: some View {
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(0.5), .black.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: width / 2))
            .frame(width: width * max(0.22, abs(cos(yaw * .pi / 180))), height: width * 0.14)
            .allowsHitTesting(false)
    }
}

/// Tilts a view in one rotation, its turn and tip combined, so the view
/// is projected once and stays rigid, where two chained rotations each
/// project it again and bend it. Animates through the turn and tip.
struct Tilt: ViewModifier, Animatable {
    var yaw: Double
    var pitch: Double
    var perspective: CGFloat = 0.4

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(yaw, pitch) }
        set { yaw = newValue.first; pitch = newValue.second }
    }

    func body(content: Content) -> some View {
        let rotation = simd_quatd(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0))
            * simd_quatd(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0))
        let axis = rotation.angle == 0 ? SIMD3<Double>(0, 1, 0) : rotation.axis
        content.rotation3DEffect(.radians(rotation.angle), axis: (x: axis.x, y: axis.y, z: axis.z),
                                 perspective: perspective)
    }
}

/// A ring of sparks thrown out from behind a medal as it lands: they rise
/// and fade over `progress` from 0 to 1, and are gone at both ends.
private struct SparkBurst: View, Animatable {
    let color: Color
    let radius: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let count = 10

    var body: some View {
        ZStack {
            ForEach(0..<Self.count, id: \.self) { index in
                // Alternate sparks sit nearer and smaller, so the ring reads as thrown.
                let near = index.isMultiple(of: 2)
                let angle = Double(index) / Double(Self.count) * 2 * .pi + (near ? 0 : 0.2)
                let distance = radius * ((near ? 0.62 : 0.72) + 0.4 * progress)
                Image(systemName: "sparkle")
                    .font(.system(size: radius * (near ? 0.07 : 0.1), weight: .bold))
                    .foregroundStyle(color)
                    .scaleEffect(0.4 + 0.8 * progress)
                    .opacity(sin(progress * CGFloat.pi))
                    .offset(x: distance * cos(angle), y: distance * sin(angle))
            }
        }
        .allowsHitTesting(false)
    }
}
