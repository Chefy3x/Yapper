import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Opt-in: renders every mouth shape as the director would show it when the net is sure, at a quiet,
/// a normal and a loud syllable, to set side by side with reference video of a real mouth.
/// YAPPER_MOUTH_SHAPE_SHEET=<folder> (TEST_RUNNER_… through xcodebuild) writes <shape>_<jaw>.png, and
/// <shape>_<jaw>_id.png: an ID map in flat colours (lips blue, teeth yellow, tongue green, gums cyan,
/// inside black) to set against the same map made from video.
struct MouthShapeSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YAPPER_MOUTH_SHAPE_SHEET"]

    @Test(.enabled(if: outDir != nil)) func sheet() throws {
        let out = URL(fileURLWithPath: Self.outDir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let asset = try MouthRigTests.asset()
        var idAsset = asset
        for i in idAsset.materials.indices {
            let m = idAsset.materials[i]
            guard m.kind != .holdout else { continue }
            let c: SIMD3<Float> = m.name.hasPrefix("Lip") ? [0, 0, 1] : m.name == "Tooth" || m.name == "Gold" ? [1, 1, 0]
                : m.name.hasPrefix("Tongue") ? [0, 1, 0] : m.name == "Gum" ? [0, 1, 1] : m.name == "Ink" ? [0, 0, 1] : [0, 0, 0]
            idAsset.materials[i] = MouthAsset.Material(name: m.name, kind: .flat, color: c)
        }
        let renderers = [(try MouthRenderer(asset: asset), ""), (try MouthRenderer(asset: idAsset), "_id")]
        let model = MouthModel(asset: asset, springs: 0)
        for shape in MouthShape.allCases {
            for J in [Float(0.2), 0.5, 0.85] {
                var shaper = MouthShaper()
                var shapes = MouthShapes(); shapes[shape.rawValue] = 1
                var lips = MouthShaper.Lips()
                for _ in 0..<60 { lips = shaper.step(shapes, dt: 0.01) }
                var performance = MouthPerformance()
                var acted = performance.step(J: J, W: MouthShaper.width(lips), T: 0, dt: 0.01)
                for _ in 0..<5 { acted = performance.step(J: J, W: MouthShaper.width(lips), T: 0, dt: 0.01) }
                var pose = acted.pose
                MouthShaper.apply(lips, to: &pose)
                model.pose(pose, dt: 0)
                for (renderer, suffix) in renderers {
                    let image = try #require(renderer.image(model, framing: MouthFraming(rotationDegrees: asset.view.rotationDegrees),
                                                            width: 420, height: 300))
                    let url = out.appendingPathComponent("\(shape)_\(J)\(suffix).png")
                    let dst = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(dst, image, nil)
                    CGImageDestinationFinalize(dst)
                }
            }
        }
    }
}
