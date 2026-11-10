//
//  ProviderLogo.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import SwiftUI

/// A provider's mark in its own colour, where a list names providers. The
/// marks are the providers' trademarks, bundled as published (see
/// ProviderLogos/README.md); a mark that cannot be read falls back to a dot.
struct ProviderLogo: View {
    let provider: ProviderKey
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let mark = Self.marks[provider] {
                MarkShape(mark: mark).fill(Palette.accent(provider))
            } else {
                Circle().fill(Palette.accent(provider)).padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }

    /// Every mark is drawn on Simple Icons' 24-point square.
    nonisolated static let viewBox: CGFloat = 24

    static let marks: [ProviderKey: Path] = Dictionary(uniqueKeysWithValues: ProviderKey.allCases.compactMap { provider in
        guard let url = Bundle.module.url(forResource: file(provider), withExtension: "svg",
                                          subdirectory: "ProviderLogos"),
              let svg = try? String(contentsOf: url, encoding: .utf8),
              let data = svg.firstMatch(of: /\sd="([^"]+)"/)?.1,
              let path = SVGPathReader.path(String(data)) else { return nil }
        return (provider, path)
    })

    /// Codex is OpenAI's, so it carries OpenAI's mark.
    static func file(_ provider: ProviderKey) -> String {
        switch provider {
        case .codex: "openai"
        case .claudeCode: "claude"
        case .cursor: "cursor"
        }
    }
}

/// A mark scaled from its view box to whatever square it is given.
private struct MarkShape: Shape {
    let mark: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / ProviderLogo.viewBox
        return mark.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Reads SVG path data into a Path: M L H V C S Q T A Z, absolute and
/// relative, with implicit repeats and the compact numbers icon sets use
/// ("-.42.726" is two numbers). Arcs become cubic curves. Nil for data it
/// cannot read, rather than a partial shape.
struct SVGPathReader {
    private let bytes: [UInt8]
    private var index = 0

    private init(_ data: String) { bytes = Array(data.utf8) }

    static func path(_ data: String) -> Path? {
        var reader = SVGPathReader(data)
        return reader.read()
    }

    private mutating func read() -> Path? {
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        // The previous segment's last control point, for S and T to reflect.
        var cubicControl: CGPoint?, quadControl: CGPoint?
        var command: UInt8 = 0

        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            if Self.isLetter(bytes[index]) {
                command = bytes[index]
                index += 1
            } else if command == 0 || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                return nil
            } else if command == UInt8(ascii: "M") {
                // Pairs after a move are lines.
                command = UInt8(ascii: "L")
            } else if command == UInt8(ascii: "m") {
                command = UInt8(ascii: "l")
            }
            let relative = command >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            var nextCubic: CGPoint?, nextQuad: CGPoint?

            switch command & ~0x20 {  // upper case
            case UInt8(ascii: "M"):
                guard let point = point(base) else { return nil }
                path.move(to: point)
                current = point
                start = point
            case UInt8(ascii: "L"):
                guard let point = point(base) else { return nil }
                path.addLine(to: point)
                current = point
            case UInt8(ascii: "H"):
                guard let x = number() else { return nil }
                current = CGPoint(x: x + base.x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "V"):
                guard let y = number() else { return nil }
                current = CGPoint(x: current.x, y: y + base.y)
                path.addLine(to: current)
            case UInt8(ascii: "C"):
                guard let first = point(base), let second = point(base), let end = point(base) else { return nil }
                path.addCurve(to: end, control1: first, control2: second)
                nextCubic = second
                current = end
            case UInt8(ascii: "S"):
                guard let second = point(base), let end = point(base) else { return nil }
                let first = cubicControl.map { Self.reflect($0, about: current) } ?? current
                path.addCurve(to: end, control1: first, control2: second)
                nextCubic = second
                current = end
            case UInt8(ascii: "Q"):
                guard let control = point(base), let end = point(base) else { return nil }
                path.addQuadCurve(to: end, control: control)
                nextQuad = control
                current = end
            case UInt8(ascii: "T"):
                guard let end = point(base) else { return nil }
                let control = quadControl.map { Self.reflect($0, about: current) } ?? current
                path.addQuadCurve(to: end, control: control)
                nextQuad = control
                current = end
            case UInt8(ascii: "A"):
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let large = flag(), let sweep = flag(), let end = point(base) else { return nil }
                Self.addArc(to: &path, from: current, to: end, radii: CGSize(width: rx, height: ry),
                            rotation: rotation, large: large, sweep: sweep)
                current = end
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                current = start
            default:
                return nil
            }
            cubicControl = nextCubic
            quadControl = nextQuad
        }
        return path
    }

    // MARK: Scanning

    private static func isLetter(_ byte: UInt8) -> Bool {
        let upper = byte & ~0x20
        return upper >= UInt8(ascii: "A") && upper <= UInt8(ascii: "Z") && upper != UInt8(ascii: "E")
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    private mutating func skipSeparators() {
        while index < bytes.count, [UInt8(ascii: " "), UInt8(ascii: ","), 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func point(_ base: CGPoint) -> CGPoint? {
        guard let x = number(), let y = number() else { return nil }
        return CGPoint(x: x + base.x, y: y + base.y)
    }

    /// A number ends at a second point or a sign, so ".079-.2307" is two.
    private mutating func number() -> CGFloat? {
        skipSeparators()
        let begin = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var digits = false, point = false
        while index < bytes.count {
            let byte = bytes[index]
            if Self.isDigit(byte) {
                digits = true
            } else if byte == UInt8(ascii: "."), !point {
                point = true
            } else {
                break
            }
            index += 1
        }
        guard digits else { index = begin; return nil }
        if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
            let mark = index
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            if index < bytes.count, Self.isDigit(bytes[index]) {
                while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            } else {
                index = mark
            }
        }
        return Double(String(decoding: bytes[begin..<index], as: UTF8.self)).map { CGFloat($0) }
    }

    /// An arc flag is one character, and may run straight into the next.
    private mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { return nil }
        defer { index += 1 }
        return bytes[index] == UInt8(ascii: "1")
    }

    // MARK: Geometry

    private static func reflect(_ point: CGPoint, about center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// The SVG endpoint arc as cubic curves of at most a quarter turn each,
    /// by the conversion in the SVG specification's implementation notes.
    private static func addArc(to path: inout Path, from start: CGPoint, to end: CGPoint, radii: CGSize,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        guard start != end else { return }
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0 else { path.addLine(to: end); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        // Radii too small to reach are scaled up until they just do.
        let reach = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if reach > 1 { rx *= reach.squareRoot(); ry *= reach.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (large == sweep ? -1 : 1) * max(0, numerator / denominator).squareRoot()
        let cx1 = coefficient * rx * y1 / ry, cy1 = -coefficient * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
                             y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)
        func angle(_ u: CGPoint, _ v: CGPoint) -> CGFloat { atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y) }
        let u = CGPoint(x: (x1 - cx1) / rx, y: (y1 - cy1) / ry)
        let v = CGPoint(x: (-x1 - cx1) / rx, y: (-y1 - cy1) / ry)
        let theta = angle(CGPoint(x: 1, y: 0), u)
        var delta = angle(u, v)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        func onEllipse(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * x - ry * sinPhi * y, y: center.y + rx * sinPhi * x + ry * cosPhi * y)
        }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)
        for segment in 0..<segments {
            let a1 = theta + CGFloat(segment) * step, a2 = a1 + step
            let (c1, s1, c2, s2) = (cos(a1), sin(a1), cos(a2), sin(a2))
            let last = segment == segments - 1
            path.addCurve(to: last ? end : onEllipse(c2, s2),
                          control1: onEllipse(c1 - handle * s1, s1 + handle * c1),
                          control2: onEllipse(c2 + handle * s2, s2 - handle * c2))
        }
    }
}
