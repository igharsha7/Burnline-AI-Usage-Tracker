//
//  LandmarkArt.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// Each landmark drawn as itself: the leaning tower with its galleries, the
/// statue with her torch, the pyramids of Giza, the Eiffel Tower's legs and
/// arch, the setbacks of the Empire State, Taipei 101's stacked pagoda, the
/// Shanghai Tower's twist, the Burj Khalifa's spire, Angel Falls pouring off
/// its tepui, Table Mountain's plateau, Vesuvius and its crater, Fuji's
/// snow-capped cone, the Matterhorn's horn, Kilimanjaro's glaciers, Everest
/// with its snow line, a rocket crossing into space and the station with its
/// solar wings.
/// Drawn in a unit square from simple parts joined into one outline, then
/// fitted to the frame, so it engraves a medal and fills the climb alike.
struct LandmarkArt: Shape {
    let silhouette: Landmark.Silhouette
    /// Whether the details (a mountain's snow line and ridge, the Shanghai
    /// Tower's groove, the falls, the rocket's window) are cut out of the shape, as
    /// engraved on a medal or filled solid. Drawn in outline, they are left
    /// whole and drawn over it from `details`, `snow` and `shade` instead.
    var carved = true

    /// Width over height, so the art keeps its proportions in any frame.
    static func aspect(_ silhouette: Landmark.Silhouette) -> CGFloat {
        switch silhouette {
        case .leaningTower: 0.5
        case .statue: 0.46
        case .pyramid: 1.7
        case .needle: 0.42
        case .bridgeTower: 0.9
        case .observatory: 2.2
        case .halfDome: 1.6
        case .airliner: 3
        case .concorde: 3.6
        case .weatherBalloon: 0.5
        case .recordBalloon: 0.42
        case .satellite: 1.5
        case .lattice: 0.62
        case .steppedTower: 0.42
        case .pagoda: 0.36
        case .twistedTower: 0.34
        case .spire: 0.3
        case .waterfall: 1.3
        case .tableMountain: 2.6
        case .volcano: 2.2
        case .cone: 2.4
        case .horn: 1.25
        case .snowDome: 3.2
        case .mountain: 1.7
        case .edgeOfSpace: 0.46
        case .orbit: 1.8
        }
    }

    func path(in rect: CGRect) -> Path {
        // The tower of Pisa leans, sheared about its middle so it stays in
        // its frame; everything is then fitted to the frame, y turned down.
        let lean: CGFloat = silhouette == .leaningTower ? 0.14 : 0
        let shear = CGAffineTransform(a: 1, b: 0, c: lean, d: 1, tx: -lean / 2, ty: 0)
        let fit = CGAffineTransform(a: rect.width, b: 0, c: 0, d: -rect.height, tx: rect.minX, ty: rect.maxY)
        let outline = Self.unit(silhouette)
        let shape = carved ? Self.cuts(silhouette).map { outline.subtracting($0) } ?? outline : outline
        return shape.applying(shear.concatenating(fit))
    }

    /// The details cut out of a carved shape, fitted to `rect`.
    static func details(_ silhouette: Landmark.Silhouette, in rect: CGRect) -> Path? {
        cuts(silhouette).map { $0.applying(fit(rect)) }
    }

    /// A mountain's snowfield, fitted to `rect`, for an outline to shade.
    static func snow(_ silhouette: Landmark.Silhouette, in rect: CGRect) -> Path? {
        relief(silhouette)?.snowfield.map { $0.applying(fit(rect)) }
    }

    /// A mountain's face away from the light, fitted to `rect`.
    static func shade(_ silhouette: Landmark.Silhouette, in rect: CGRect) -> Path? {
        relief(silhouette)?.shade.map { polygon($0).applying(fit(rect)) }
    }

    /// Where across its frame the landmark's highest point stands, 0 to 1.
    static func peak(_ silhouette: Landmark.Silhouette) -> CGFloat {
        switch silhouette {
        case .mountain: 0.56
        case .horn: 0.6
        case .volcano: 0.68
        case .tableMountain: 0.55
        case .snowDome: 0.52
        case .halfDome: 0.6
        default: 0.5
        }
    }

    private static func fit(_ rect: CGRect) -> CGAffineTransform {
        CGAffineTransform(a: rect.width, b: 0, c: 0, d: -rect.height, tx: rect.minX, ty: rect.maxY)
    }

    // MARK: Drawing in the unit square

    private static func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Path {
        Path(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    private static func centered(_ width: CGFloat, _ y0: CGFloat, _ y1: CGFloat, at x: CGFloat = 0.5) -> Path {
        box(x - width / 2, y0, x + width / 2, y1)
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { path in
            path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
            path.closeSubpath()
        }
    }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
    }

    private static func joined(_ parts: [Path]) -> Path {
        parts.dropFirst().reduce(parts[0]) { $0.union($1) }
    }

    static func unit(_ silhouette: Landmark.Silhouette) -> Path {
        switch silhouette {
        case .leaningTower:
            // A base, five arcaded galleries each with its ledge, the belfry.
            var parts = [centered(0.34, 0, 0.16)]
            for gallery in 0..<5 {
                let low = 0.16 + CGFloat(gallery) * 0.13
                parts.append(centered(0.31, low, low + 0.13))
                parts.append(centered(0.39, low, low + 0.022))
            }
            parts += [centered(0.39, 0.81, 0.832), centered(0.25, 0.81, 0.94), centered(0.3, 0.94, 0.96),
                      ellipse(0.5, 0.96, 0.09, 0.04)]
            return joined(parts)
        case .statue:
            return joined([
                box(0.14, 0, 0.86, 0.05),
                polygon([(0.27, 0.05), (0.73, 0.05), (0.68, 0.38), (0.32, 0.38)]),
                box(0.29, 0.38, 0.71, 0.41),
                polygon([(0.38, 0.41), (0.62, 0.41), (0.58, 0.70), (0.42, 0.70)]),
                box(0.32, 0.52, 0.4, 0.63),
                ellipse(0.5, 0.745, 0.065, 0.045),
                polygon([(0.41, 0.77), (0.43, 0.83), (0.465, 0.785), (0.5, 0.845), (0.535, 0.785),
                         (0.57, 0.83), (0.59, 0.77)]),
                polygon([(0.55, 0.67), (0.6, 0.68), (0.665, 0.915), (0.625, 0.925)]),
                box(0.6, 0.915, 0.69, 0.945),
                ellipse(0.645, 0.97, 0.035, 0.035),
            ])
        case .pyramid:
            // Khufu's, with Khafre's beside it.
            return joined([polygon([(0, 0), (0.4, 1), (0.8, 0)]), polygon([(0.62, 0), (0.82, 0.52), (1, 0)])])
        case .needle:
            // Three legs pinched at the waist, the column, the saucer, the spire.
            return joined([
                polygon([(0.28, 0), (0.38, 0), (0.47, 0.45), (0.53, 0.45), (0.62, 0), (0.72, 0), (0.55, 0.5),
                         (0.45, 0.5)]),
                polygon([(0.45, 0.45), (0.55, 0.45), (0.535, 0.72), (0.465, 0.72)]),
                polygon([(0.06, 0.765), (0.28, 0.72), (0.72, 0.72), (0.94, 0.765), (0.8, 0.81), (0.2, 0.81)]),
                box(0.38, 0.81, 0.62, 0.86), polygon([(0.3, 0.86), (0.7, 0.86), (0.6, 0.89), (0.4, 0.89)]),
                centered(0.025, 0.89, 1),
            ])
        case .bridgeTower:
            // One of the towers: two legs under portal beams, the deck, and
            // the main cables sweeping down either side.
            var parts = [polygon([(0.38, 0), (0.45, 0), (0.445, 1), (0.405, 1)]),
                         polygon([(0.55, 0), (0.62, 0), (0.595, 1), (0.555, 1)]),
                         box(0, 0.2, 1, 0.24)]
            for y in [0.38, 0.6, 0.8, 0.95] as [CGFloat] { parts.append(box(0.42, y, 0.58, y + 0.04)) }
            for side in [0.0, 1.0] as [CGFloat] {
                parts.append(Path { path in
                    path.move(to: CGPoint(x: side == 0 ? 0.41 : 0.59, y: 0.99))
                    path.addQuadCurve(to: CGPoint(x: side, y: 0.3), control: CGPoint(x: side == 0 ? 0.2 : 0.8, y: 0.3))
                }.strokedPath(StrokeStyle(lineWidth: 0.014)))
            }
            return joined(parts)
        case .lattice:
            let tower = Path { path in
                path.move(to: CGPoint(x: 0.04, y: 0))
                path.addQuadCurve(to: CGPoint(x: 0.42, y: 0.58), control: CGPoint(x: 0.3, y: 0.16))
                path.addLine(to: CGPoint(x: 0.455, y: 0.87))
                path.addLine(to: CGPoint(x: 0.5, y: 1))
                path.addLine(to: CGPoint(x: 0.545, y: 0.87))
                path.addLine(to: CGPoint(x: 0.58, y: 0.58))
                path.addQuadCurve(to: CGPoint(x: 0.96, y: 0), control: CGPoint(x: 0.7, y: 0.16))
                path.addLine(to: CGPoint(x: 0.75, y: 0))
                // The great arch between the legs.
                path.addQuadCurve(to: CGPoint(x: 0.25, y: 0), control: CGPoint(x: 0.5, y: 0.32))
                path.closeSubpath()
            }
            return joined([tower, box(0.17, 0.2, 0.83, 0.235), box(0.37, 0.56, 0.63, 0.585),
                           box(0.43, 0.86, 0.57, 0.875)])
        case .steppedTower:
            return joined([
                box(0.1, 0, 0.9, 0.12), centered(0.62, 0.12, 0.5), centered(0.46, 0.5, 0.62),
                centered(0.34, 0.62, 0.7), centered(0.24, 0.7, 0.76),
                polygon([(0.39, 0.76), (0.61, 0.76), (0.55, 0.83), (0.45, 0.83)]),
                centered(0.06, 0.83, 0.94), centered(0.02, 0.94, 1),
            ])
        case .pagoda:
            // Eight flared sections, each wider at its top, over a tapered base.
            var parts = [polygon([(0.18, 0), (0.82, 0), (0.75, 0.2), (0.25, 0.2)])]
            for section in 0..<8 {
                let low = 0.2 + CGFloat(section) * 0.075, high = low + 0.075
                parts.append(polygon([(0.3, low), (0.7, low), (0.79, high), (0.21, high)]))
            }
            parts += [centered(0.3, 0.8, 0.86), centered(0.16, 0.86, 0.9), centered(0.035, 0.9, 1)]
            return joined(parts)
        case .twistedTower:
            let tower = Path { path in
                path.move(to: CGPoint(x: 0.12, y: 0))
                path.addCurve(to: CGPoint(x: 0.34, y: 0.95), control1: CGPoint(x: 0.16, y: 0.5),
                              control2: CGPoint(x: 0.26, y: 0.8))
                path.addLine(to: CGPoint(x: 0.66, y: 1))
                path.addCurve(to: CGPoint(x: 0.88, y: 0), control1: CGPoint(x: 0.76, y: 0.72),
                              control2: CGPoint(x: 0.86, y: 0.4))
                path.closeSubpath()
            }
            return tower
        case .spire:
            // Setbacks stepping in, alternately from each side, to the spire.
            let tiers: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (0.1, 0, 0.9, 0.06), (0.16, 0.06, 0.84, 0.16), (0.2, 0.16, 0.78, 0.26), (0.26, 0.26, 0.74, 0.36),
                (0.29, 0.36, 0.69, 0.46), (0.34, 0.46, 0.65, 0.55), (0.37, 0.55, 0.61, 0.63), (0.41, 0.63, 0.58, 0.7),
            ]
            return joined(tiers.map { box($0.0, $0.1, $0.2, $0.3) }
                          + [polygon([(0.44, 0.7), (0.56, 0.7), (0.505, 1)])])
        case .mountain:
            return massif.outline
        case .cone:
            return fuji.outline
        case .horn:
            return matterhorn.outline
        case .snowDome:
            return kilimanjaro.outline
        case .volcano:
            return vesuvius.outline
        case .observatory:
            return washington.outline
        case .halfDome:
            return halfDome.outline
        case .tableMountain:
            // The plateau, with Devil's Peak at its left shoulder.
            return polygon([
                (0, 0), (0.06, 0.2), (0.1, 0.42), (0.12, 0.6), (0.15, 0.86), (0.18, 0.8), (0.22, 0.9),
                (0.26, 0.97), (0.3, 1), (0.8, 0.995), (0.84, 0.95), (0.87, 0.78), (0.9, 0.56), (0.95, 0.28), (1, 0),
            ])
        case .waterfall:
            // Auyán-tepui: sheer walls under a flat, ragged top.
            return polygon([
                (0, 0), (0.04, 0.18), (0.08, 0.4), (0.1, 0.7), (0.12, 0.9), (0.16, 0.97), (0.3, 1), (0.55, 0.985),
                (0.8, 1), (0.86, 0.96), (0.88, 0.86), (0.9, 0.6), (0.93, 0.36), (0.97, 0.16), (1, 0),
            ])
        case .airliner:
            // In profile: fuselage, tail fin and tailplane, swept wing, an engine.
            return joined([
                polygon([(0.03, 0.5), (0.08, 0.6), (0.86, 0.6), (0.95, 0.56), (0.99, 0.5), (0.95, 0.44),
                         (0.86, 0.4), (0.12, 0.4)]),
                polygon([(0.04, 0.58), (0.07, 1), (0.14, 1), (0.22, 0.58)]),
                polygon([(0.02, 0.52), (0.18, 0.5), (0.14, 0.46), (0.03, 0.47)]),
                polygon([(0.4, 0.45), (0.6, 0.45), (0.44, 0.22), (0.38, 0.22)]),
                Path(roundedRect: CGRect(x: 0.5, y: 0.3, width: 0.13, height: 0.11), cornerSize: CGSize(width: 0.03, height: 0.05)),
            ])
        case .concorde:
            // In profile: the slender fuselage, the drooped needle nose, the
            // tall fin, the engines under the delta.
            return joined([
                polygon([(0.02, 0.5), (0.06, 0.56), (0.8, 0.57), (0.9, 0.54), (1, 0.44), (0.9, 0.48),
                         (0.8, 0.46), (0.06, 0.45)]),
                polygon([(0.03, 0.55), (0.1, 1), (0.16, 1), (0.24, 0.56)]),
                polygon([(0.14, 0.46), (0.6, 0.46), (0.22, 0.3), (0.14, 0.3)]),
                box(0.2, 0.2, 0.44, 0.31),
            ])
        case .weatherBalloon:
            return joined([
                ellipse(0.5, 0.74, 0.46, 0.23),
                polygon([(0.46, 0.52), (0.54, 0.52), (0.52, 0.48), (0.48, 0.48)]),
                centered(0.02, 0.1, 0.49), box(0.4, 0, 0.6, 0.1),
            ])
        case .recordBalloon:
            // A zero-pressure balloon at float: a tall teardrop of film.
            let envelope = Path { path in
                path.move(to: CGPoint(x: 0.5, y: 0.3))
                path.addCurve(to: CGPoint(x: 0.5, y: 1), control1: CGPoint(x: 0.02, y: 0.5),
                              control2: CGPoint(x: 0, y: 0.98))
                path.addCurve(to: CGPoint(x: 0.5, y: 0.3), control1: CGPoint(x: 1, y: 0.98),
                              control2: CGPoint(x: 0.98, y: 0.5))
                path.closeSubpath()
            }
            return joined([envelope, centered(0.024, 0.08, 0.31), box(0.38, 0, 0.62, 0.08)])
        case .satellite:
            // Sputnik 1: the polished sphere and its four trailing antennas.
            var parts = [ellipse(0.32, 0.62, 0.17, 0.255)]
            for end in [(1.0, 0.18), (0.96, 0.04), (0.88, 0.0), (0.98, 0.32)] as [(CGFloat, CGFloat)] {
                parts.append(Path { path in
                    path.move(to: CGPoint(x: 0.4, y: 0.56))
                    path.addLine(to: CGPoint(x: end.0, y: end.1))
                }.strokedPath(StrokeStyle(lineWidth: 0.018, lineCap: .round)))
            }
            return joined(parts)
        case .edgeOfSpace:
            // A rocket crossing into space.
            let nose = Path { path in
                path.move(to: CGPoint(x: 0.36, y: 0.74))
                path.addQuadCurve(to: CGPoint(x: 0.5, y: 1), control: CGPoint(x: 0.36, y: 0.93))
                path.addQuadCurve(to: CGPoint(x: 0.64, y: 0.74), control: CGPoint(x: 0.64, y: 0.93))
                path.closeSubpath()
            }
            let rocket = joined([
                box(0.36, 0.24, 0.64, 0.74), nose,
                polygon([(0.36, 0.42), (0.12, 0.2), (0.12, 0.08), (0.36, 0.26)]),
                polygon([(0.64, 0.42), (0.88, 0.2), (0.88, 0.08), (0.64, 0.26)]),
                box(0.42, 0.17, 0.58, 0.24),
                polygon([(0.42, 0.15), (0.5, 0), (0.58, 0.15)]),
            ])
            return rocket
        case .orbit:
            // The station: a long truss, four pairs of solar wings, modules.
            var parts = [box(0.03, 0.47, 0.97, 0.53), box(0.41, 0.36, 0.59, 0.64), box(0.47, 0.18, 0.53, 0.36)]
            for x in [0.11, 0.25, 0.75, 0.89] as [CGFloat] {
                parts += [box(x - 0.05, 0.57, x + 0.05, 0.98), box(x - 0.05, 0.02, x + 0.05, 0.43),
                          box(x - 0.008, 0.43, x + 0.008, 0.57)]
            }
            return joined(parts)
        }
    }

    // MARK: Details

    /// What a carved shape has cut out of it: a mountain's snow line and
    /// ridge, the Shanghai Tower's groove, the falls and their mist, Table
    /// Mountain's cliff band, the rocket's window.
    private static func cuts(_ silhouette: Landmark.Silhouette) -> Path? {
        if let relief = relief(silhouette), let edge = relief.snowEdge {
            var cut = lines(edge).strokedPath(StrokeStyle(lineWidth: 0.022, lineCap: .round, lineJoin: .round))
            if let ridge = relief.ridge {
                cut = cut.union(lines(ridge).strokedPath(StrokeStyle(lineWidth: 0.014, lineCap: .round)))
            }
            return cut
        }
        switch silhouette {
        case .twistedTower:
            return Path { path in
                path.move(to: CGPoint(x: 0.7, y: 0))
                path.addCurve(to: CGPoint(x: 0.5, y: 0.97), control1: CGPoint(x: 0.62, y: 0.4),
                              control2: CGPoint(x: 0.48, y: 0.7))
            }.strokedPath(StrokeStyle(lineWidth: 0.05))
        case .waterfall:
            // The falls: a ribbon off the lip, widening into spray below.
            return polygon([(0.455, 0.985), (0.475, 0.985), (0.48, 0.6), (0.5, 0.22), (0.53, 0.06),
                            (0.41, 0.06), (0.44, 0.22), (0.452, 0.6)])
        case .tableMountain:
            return lines([(0.27, 0.86), (0.4, 0.855), (0.55, 0.865), (0.7, 0.855), (0.83, 0.86)])
                .strokedPath(StrokeStyle(lineWidth: 0.012, lineCap: .round))
        case .edgeOfSpace:
            return ellipse(0.5, 0.58, 0.07, 0.07 * 0.46)
        default:
            return nil
        }
    }

    private static func lines(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { $0.addLines(points.map { CGPoint(x: $0.0, y: $0.1) }) }
    }

    /// A mountain drawn in relief: its outline, the snowfield over its top
    /// down to a ragged snow line, the ridge from its summit and the face
    /// turned from the light.
    private struct Relief {
        let outline: Path
        /// The snowfield's top, along the outline from the snow line's left
        /// end over the summit to its right end.
        var snowTop: [(CGFloat, CGFloat)]?
        /// The snow line, left to right, ragged where rock shows through.
        var snowEdge: [(CGFloat, CGFloat)]?
        var ridge: [(CGFloat, CGFloat)]?
        var shade: [(CGFloat, CGFloat)]?

        var snowfield: Path? {
            guard let snowTop, let snowEdge else { return nil }
            return polygon(snowTop + snowEdge.reversed())
        }
    }

    private static func relief(_ silhouette: Landmark.Silhouette) -> Relief? {
        switch silhouette {
        case .mountain: massif
        case .cone: fuji
        case .horn: matterhorn
        case .snowDome: kilimanjaro
        case .volcano: vesuvius
        case .observatory: washington
        case .halfDome: halfDome
        default: nil
        }
    }

    /// Everest from the south: Nuptse's shoulder on the left, the summit
    /// pyramid, the col and Lhotse to the right, falling to a broad base.
    private static let massif: Relief = {
        let ridgeline: [(CGFloat, CGFloat)] = [
            (0.6, 0.91), (0.64, 0.84), (0.68, 0.8), (0.72, 0.74), (0.75, 0.77), (0.78, 0.8),
        ]
        return Relief(
            outline: polygon([
                (0, 0), (0.06, 0.08), (0.12, 0.17), (0.17, 0.22), (0.22, 0.34), (0.27, 0.42), (0.31, 0.46),
                (0.35, 0.44), (0.4, 0.55), (0.45, 0.66), (0.49, 0.76), (0.53, 0.9), (0.56, 1),
            ] + ridgeline + [(0.82, 0.68), (0.86, 0.54), (0.9, 0.4), (0.94, 0.22), (0.97, 0.1), (1, 0)]),
            snowTop: [(0.455, 0.675), (0.49, 0.76), (0.53, 0.9), (0.56, 1)] + ridgeline + [(0.805, 0.72)],
            snowEdge: [(0.455, 0.675), (0.48, 0.69), (0.51, 0.64), (0.55, 0.69), (0.58, 0.62), (0.62, 0.7),
                       (0.66, 0.63), (0.7, 0.69), (0.74, 0.66), (0.77, 0.7), (0.805, 0.72)],
            ridge: [(0.56, 0.97), (0.585, 0.8), (0.6, 0.68)],
            shade: [(0.56, 1)] + ridgeline + [(0.82, 0.68), (0.86, 0.54), (0.9, 0.4), (0.94, 0.22), (0.97, 0.1),
                                              (1, 0), (0.76, 0), (0.7, 0.3), (0.64, 0.55), (0.59, 0.78)])
    }()

    /// Fuji: a near-perfect cone whose flanks steepen toward the crater,
    /// its snow reaching down in fingers.
    private static let fuji: Relief = {
        // How far in from the edge the flank is at height `h`, 0 to 1.
        func flank(_ h: CGFloat) -> CGFloat { 0.41 * (1 - pow(1 - h, 1.5)) }
        let heights = (0...10).map { CGFloat($0) / 10 }
        let summit: [(CGFloat, CGFloat)] = [(0.45, 1), (0.5, 0.985), (0.55, 1)]
        let snowLine: CGFloat = 0.64
        let upper = heights.filter { $0 > snowLine }
        let edge = (0...10).map { i -> (CGFloat, CGFloat) in
            let x = flank(snowLine) + (1 - 2 * flank(snowLine)) * CGFloat(i) / 10
            return (x, i == 0 || i == 10 ? snowLine : (i.isMultiple(of: 2) ? 0.66 : 0.56))
        }
        return Relief(
            outline: polygon(heights.map { (flank($0), $0) } + summit + heights.reversed().map { (1 - flank($0), $0) }),
            snowTop: [(flank(snowLine), snowLine)] + upper.map { (flank($0), $0) } + summit
                + upper.reversed().map { (1 - flank($0), $0) } + [(1 - flank(snowLine), snowLine)],
            snowEdge: edge,
            shade: summit.suffix(1) + heights.reversed().map { (1 - flank($0), $0) } + [(0.62, 0)])
    }()

    /// The Matterhorn: a crooked horn, its summit hooked toward the east.
    private static let matterhorn: Relief = {
        let east: [(CGFloat, CGFloat)] = [(0.66, 0.97), (0.67, 0.9), (0.72, 0.76), (0.78, 0.62)]
        let below: [(CGFloat, CGFloat)] = [(0.82, 0.56), (0.87, 0.42), (0.93, 0.22), (1, 0)]
        return Relief(
            outline: polygon([(0, 0), (0.1, 0.1), (0.2, 0.22), (0.27, 0.3), (0.33, 0.34), (0.4, 0.48), (0.47, 0.64),
                              (0.52, 0.78), (0.56, 0.9), (0.6, 1)] + east + below),
            snowTop: [(0.47, 0.64), (0.52, 0.78), (0.56, 0.9), (0.6, 1)] + east,
            snowEdge: [(0.47, 0.64), (0.5, 0.6), (0.53, 0.66), (0.57, 0.56), (0.6, 0.64), (0.64, 0.55),
                       (0.68, 0.63), (0.72, 0.57), (0.75, 0.63), (0.78, 0.62)],
            ridge: [(0.6, 0.98), (0.625, 0.8), (0.645, 0.62)],
            shade: [(0.6, 1)] + east + below + [(0.74, 0), (0.68, 0.4), (0.63, 0.8)])
    }()

    /// Kilimanjaro: Kibo's broad dome under its glaciers, Mawenzi's jagged
    /// peak on its eastern shoulder.
    private static let kilimanjaro: Relief = {
        let crown: [(CGFloat, CGFloat)] = [(0.35, 0.84), (0.4, 0.93), (0.46, 0.98), (0.52, 1), (0.6, 0.99),
                                           (0.66, 0.95), (0.7, 0.88)]
        let east: [(CGFloat, CGFloat)] = [(0.74, 0.78), (0.78, 0.66), (0.81, 0.62), (0.84, 0.7), (0.86, 0.74),
                                          (0.88, 0.66), (0.92, 0.42), (0.96, 0.2), (1, 0)]
        return Relief(
            outline: polygon([(0, 0), (0.08, 0.14), (0.16, 0.32), (0.24, 0.52), (0.3, 0.7)] + crown + east),
            snowTop: [(0.33, 0.8)] + crown + [(0.72, 0.83)],
            snowEdge: [(0.33, 0.8), (0.37, 0.83), (0.4, 0.78), (0.44, 0.86), (0.48, 0.8), (0.52, 0.88),
                       (0.56, 0.81), (0.6, 0.87), (0.64, 0.8), (0.68, 0.84), (0.72, 0.83)],
            shade: Array(crown.suffix(4)) + east + [(0.7, 0), (0.6, 0.5)])
    }()

    /// Vesuvius: the cone rising inside the old Somma ridge, its crater's
    /// rim highest on the east.
    private static let vesuvius: Relief = {
        let east: [(CGFloat, CGFloat)] = [(0.68, 1), (0.74, 0.84), (0.82, 0.6), (0.9, 0.34), (1, 0)]
        return Relief(
            outline: polygon([(0, 0), (0.1, 0.24), (0.2, 0.5), (0.26, 0.64), (0.31, 0.71), (0.35, 0.72),
                              (0.39, 0.66), (0.43, 0.6), (0.47, 0.68), (0.52, 0.84), (0.56, 0.96), (0.6, 0.92),
                              (0.64, 0.92)] + east),
            shade: east + [(0.78, 0), (0.7, 0.5), (0.66, 0.92)])
    }()

    /// Mount Washington: a broad, rounded summit with its weather
    /// observatory's tower and mast on top.
    private static let washington: Relief = {
        let east: [(CGFloat, CGFloat)] = [(0.58, 0.82), (0.66, 0.72), (0.76, 0.52), (0.86, 0.3), (1, 0)]
        return Relief(
            outline: joined([
                polygon([(0, 0), (0.1, 0.18), (0.2, 0.38), (0.3, 0.56), (0.38, 0.7), (0.44, 0.8), (0.5, 0.84)] + east),
                box(0.48, 0.83, 0.52, 0.93), box(0.495, 0.93, 0.505, 1),
            ]),
            shade: [(0.5, 0.84)] + east + [(0.72, 0), (0.6, 0.5)])
    }()

    /// Half Dome: granite rounded on the west, sheared sheer on the east.
    private static let halfDome: Relief = {
        let face: [(CGFloat, CGFloat)] = [(0.66, 0.98), (0.7, 0.95), (0.71, 0.6), (0.72, 0.3), (0.78, 0.12),
                                          (0.88, 0.05), (1, 0)]
        return Relief(
            outline: polygon([(0, 0), (0.08, 0.22), (0.16, 0.46), (0.24, 0.66), (0.32, 0.82), (0.42, 0.94),
                              (0.52, 0.99), (0.6, 1)] + face),
            shade: face + [(0.6, 0), (0.62, 0.5)])
    }()
}
