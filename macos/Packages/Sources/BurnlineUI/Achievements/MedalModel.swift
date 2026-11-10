//
//  MedalModel.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import os
import SceneKit
import SwiftUI

/// A medal as a real solid, for the detail and the arrival: its outline
/// extruded with rounded edges and cast in physically based metal, lit by a
/// studio it reflects, its face and back printed from the 2D medal's art.
/// Turning it moves the solid, never the art, so the face keeps its shape
/// at every angle.
///
/// SwiftUI does not step a representable through an animation, so the turn
/// animates here, in a plain view, and each frame hands SceneKit its angle.
struct MedalScene: View, Animatable {
    let form: MedalForm
    let metal: Metal?
    let face: MedalFace
    let title: String
    let date: String?
    let secret: Bool
    let name: String?
    var yaw: Double
    var pitch: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(yaw, pitch) }
        set { yaw = newValue.first; pitch = newValue.second }
    }

    var body: some View {
        MedalSceneView(form: form, metal: metal, face: face, title: title, date: date, secret: secret, name: name,
                       yaw: yaw, pitch: pitch)
    }
}

/// The SceneKit view behind `MedalScene`, turned to whatever it is given.
private struct MedalSceneView: NSViewRepresentable {
    let form: MedalForm
    let metal: Metal?
    let face: MedalFace
    let title: String
    let date: String?
    let secret: Bool
    let name: String?
    let yaw: Double
    let pitch: Double

    func makeCoordinator() -> FirstFrame { FirstFrame() }

    func makeNSView(context: Context) -> SCNView {
        let model = MedalModel(form: form, metal: metal, face: face, title: title, date: date, secret: secret,
                               name: name)
        let view = SCNView(frame: .zero)
        view.scene = model.scene
        view.pointOfView = model.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        // Hidden until SceneKit has drawn the medal: before its first frame
        // the view shows an empty, light surface for a moment.
        view.alphaValue = 0
        view.delegate = context.coordinator
        context.coordinator.view = view
        model.turn(yaw: yaw, pitch: pitch)
        return view
    }

    /// Reveals the view once its first frame is drawn. SceneKit calls back
    /// on its render thread, so the callback is nonisolated and hops to the
    /// main actor only to fade the view in.
    @MainActor
    final class FirstFrame: NSObject, SCNSceneRendererDelegate {
        weak var view: SCNView?
        private nonisolated let shown = OSAllocatedUnfairLock(initialState: false)

        nonisolated func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene,
                                  atTime time: TimeInterval) {
            let first = shown.withLock { shown in
                defer { shown = true }
                return !shown
            }
            guard first else { return }
            Task { @MainActor [weak self] in
                guard let view = self?.view else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    view.animator().alphaValue = 1
                }
            }
        }
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.scene?.rootNode.childNode(withName: MedalModel.medalName, recursively: false)?
            .simdOrientation = MedalModel.orientation(yaw: yaw, pitch: pitch)
    }
}

/// The scene behind `MedalScene`, built apart from any view so it can also
/// be rendered offscreen.
@MainActor
struct MedalModel {
    let scene = SCNScene()
    let camera = SCNNode()
    let medal: SCNNode

    static let medalName = "medal"
    /// The medal's radius in scene units, its thickness, and the rounding of
    /// its edges.
    static let radius: CGFloat = 1
    static let thickness: CGFloat = 0.17
    static let chamfer: CGFloat = 0.06
    /// The camera's vertical field of view: long, as a product shot is, so
    /// the near edge does not loom.
    static let fieldOfView: CGFloat = 24
    /// How much of the view's height the medal fills: the view leaves room
    /// around it for sparks and its shadow.
    static let fill: CGFloat = 0.8
    /// The size, in points, the art is printed at, twice over in pixels:
    /// 512 pixels across, the most a medal is ever shown at on a Retina
    /// screen, and a megabyte a face.
    static let artPoints: CGFloat = 256

    init(form: MedalForm, metal: Metal?, face: MedalFace, title: String, date: String?, secret: Bool,
         name: String?) {
        let outline = Self.outline(form)
        let shape = SCNShape(path: outline, extrusionDepth: Self.thickness)
        shape.chamferRadius = Self.chamfer
        shape.chamferMode = .both
        let palette = MetalPalette.of(metal, stone: face.stone)
        let earned = metal != nil
        let bounds = outline.bounds
        let front = Self.metal(earned: earned)
        front.diffuse.contents = Self.art(MedalView(form: form, metal: metal, face: face, size: Self.artPoints,
                                                    secret: secret, flat: true))
        front.diffuse.contentsTransform = Self.mapping(bounds)
        let back = Self.metal(earned: earned)
        // SceneKit already lays the back's texture out as seen from behind.
        back.diffuse.contents = Self.art(MedalBack(form: form, metal: metal, title: secret && !earned ? "?" : title,
                                                   date: earned ? date : nil, name: earned ? name : nil,
                                                   size: Self.artPoints, mirrored: false, stone: face.stone))
        back.diffuse.contentsTransform = Self.mapping(bounds)
        let edge = Self.metal(earned: earned)
        edge.diffuse.contents = NSColor(palette.mid)
        edge.roughness.contents = earned ? 0.22 : 0.5
        // Front, back, sides, then the front and back chamfers.
        shape.materials = [front, back, edge, edge, edge]

        medal = SCNNode(geometry: shape)
        medal.name = Self.medalName
        scene.rootNode.addChildNode(medal)

        scene.lightingEnvironment.contents = Self.studio
        scene.lightingEnvironment.intensity = earned ? 2.6 : 1.6
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = earned ? 900 : 500
        key.simdEulerAngles = SIMD3(-0.55, -0.6, 0)
        scene.rootNode.addChildNode(key)

        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = Self.fieldOfView
        camera.camera?.projectionDirection = .vertical
        camera.camera?.wantsHDR = false
        let visible = 2 * Self.radius / Self.fill
        camera.simdPosition = SIMD3(0, 0, Float(visible / (2 * tan(Self.fieldOfView / 2 * .pi / 180))))
        scene.rootNode.addChildNode(camera)
    }

    func turn(yaw: Double, pitch: Double) {
        medal.simdOrientation = Self.orientation(yaw: yaw, pitch: pitch)
    }

    /// Turned `yaw` degrees about the vertical, a turn to the right showing
    /// the right edge, then tipped `pitch` degrees, a positive tip bringing
    /// the face up.
    static func orientation(yaw: Double, pitch: Double) -> simd_quatf {
        simd_quatf(angle: Float(-pitch * .pi / 180), axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: Float(yaw * .pi / 180), axis: SIMD3(0, 1, 0))
    }

    /// The medal's outline at its radius, centred, with y up as SceneKit
    /// has it, and curves kept smooth rather than faceted.
    static func outline(_ form: MedalForm) -> NSBezierPath {
        let side = 2 * radius
        let path = MedalShape(form: form).path(in: CGRect(x: -radius, y: -radius, width: side, height: side))
        var flip = CGAffineTransform(scaleX: 1, y: -1)
        let bezier = NSBezierPath(cgPath: path.cgPath.copy(using: &flip) ?? path.cgPath)
        bezier.flatness = 0.002
        return bezier
    }

    /// Maps the art, drawn over the square the outline sits in, onto the
    /// outline's own bounds, which is what SceneKit spreads a face over.
    static func mapping(_ bounds: CGRect) -> SCNMatrix4 {
        let side = 2 * radius
        let scaleX = bounds.width / side, scaleY = bounds.height / side
        let offsetX = (bounds.minX + radius) / side, offsetY = (radius - bounds.maxY) / side
        return SCNMatrix4Mult(SCNMatrix4MakeScale(scaleX, scaleY, 1), SCNMatrix4MakeTranslation(offsetX, offsetY, 0))
    }

    /// Polished metal for an earned medal; dull iron for one still to earn.
    static func metal(earned: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        // Not fully metallic, so the art's own colour still reads under the
        // reflections.
        material.metalness.contents = earned ? 0.6 : 0.35
        material.roughness.contents = earned ? 0.32 : 0.55
        return material
    }

    static func art(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.nsImage
    }

    /// A photographer's studio to reflect: dark walls, a broad softbox above
    /// and to the left, a strip light to the right and a warm floor bounce,
    /// laid out as the panorama SceneKit lights a scene with. Reflections
    /// of it are soft, so it is small: half a megabyte, made once.
    static let studio: NSImage = {
        let width = 512, height = 256
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        context.setFillColor(CGColor(gray: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func glow(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ white: CGFloat, warm: Bool = false) {
            let colors = [CGColor(red: white, green: white * (warm ? 0.85 : 1), blue: white * (warm ? 0.7 : 1), alpha: 1),
                          CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                       endCenter: CGPoint(x: x, y: y), endRadius: radius, options: [])
        }
        // The panorama's top is the sky; the front of the medal looks
        // toward its middle.
        glow(200, 190, 110, 1)
        glow(310, 145, 45, 1)
        glow(65, 125, 60, 0.5)
        glow(256, 20, 130, 0.35, warm: true)
        image.unlockFocus()
        return image
    }()
}
