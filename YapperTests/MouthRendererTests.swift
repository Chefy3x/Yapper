import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// The Metal mouth against Blender's own renders of the same poses at the same framing
/// (YapperTests/Fixtures/Mouth/ref_*.png): the silhouette must line up and the colours must agree.
/// Side-by-side PNGs land in the temp folder for a look.
struct MouthRendererTests {
    static let out = FileManager.default.temporaryDirectory.appendingPathComponent("mouth-golden")

    struct Pixels {
        var width: Int, height: Int, rgba: [UInt8]
        init(_ image: CGImage) {
            width = image.width; height = image.height
            rgba = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func alpha(_ i: Int) -> UInt8 { rgba[4 * i + 3] }
    }

    static func load(_ url: URL) throws -> CGImage {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    static func save(_ image: CGImage, _ name: String) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent(name)
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, image, nil)
        CGImageDestinationFinalize(dst)
    }

    static let poses: [(String, MouthPose)] = [
        ("rest", MouthPose()), ("ah", MouthPose(J: 1)), ("ee", MouthPose(J: 0.3, wide: 0.9)),
        ("oo", MouthPose(J: 0.1, pucker: 0.9)), ("fv", MouthPose(fv: 1)),
        ("snarl", MouthPose(J: 0.55, part: 0.3, upperUp: SIMD2(0.8, 0.9), lowerDown: SIMD2(0.5, 0.5))),
    ]

    @Test func matchesBlenderStills() throws {
        let asset = try MouthRigTests.asset()
        let renderer = try MouthRenderer(asset: asset)
        let model = MouthModel(asset: asset, springs: 0)
        for (name, pose) in Self.poses {
            model.pose(pose, dt: 0)
            let got = try #require(renderer.image(model, framing: MouthFraming(rotationDegrees: asset.view.rotationDegrees),
                                                  width: 320, height: 200))
            Self.save(got, "metal_\(name).png")
            let ref = Pixels(try Self.load(MouthRigTests.fixtures.appendingPathComponent("ref_\(name).png")))
            let mine = Pixels(got)
            #expect(ref.width == mine.width && ref.height == mine.height)
            var both = 0, either = 0, colourSum = 0, colourCount = 0
            for i in 0..<(ref.width * ref.height) {
                let a = ref.alpha(i) > 128, b = mine.alpha(i) > 128
                if a || b { either += 1 }
                if a && b {
                    both += 1
                    if ref.alpha(i) == 255 && mine.alpha(i) == 255 {
                        for c in 0..<3 { colourSum += abs(Int(ref.rgba[4 * i + c]) - Int(mine.rgba[4 * i + c])) }
                        colourCount += 3
                    }
                }
            }
            let iou = Double(both) / Double(max(1, either))
            let colour = Double(colourSum) / Double(max(1, colourCount))
            print("mouth golden \(name): silhouette IoU \(String(format: "%.3f", iou)), mean colour diff \(String(format: "%.1f", colour))/255 → \(Self.out.path)")
            #expect(iou > 0.95, "\(name): silhouette IoU \(iou)")
            #expect(colour < 14, "\(name): mean colour difference \(colour)/255")
        }
    }

    @Test func gpuSkinningMatchesTheCPUReference() throws {
        let asset = try MouthRigTests.asset()
        let renderer = try MouthRenderer(asset: asset)
        let model = MouthModel(asset: asset, springs: 0)
        for (name, pose) in Self.poses {
            model.pose(pose, dt: 0)
            for (i, mesh) in asset.meshes.enumerated() where mesh.binding == .skinned {
                var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
                MouthSkinner.skin(mesh, matrices: model.matrices, positions: &p, normals: &n)
                let gpu = try #require(renderer.skinned(model, mesh: i))
                var worstP: Float = 0, differ = 0, inked = 0
                for k in p.indices {
                    worstP = max(worstP, simd_distance(p[k], gpu.positions[k]))
                    // Where the lip's front and back pinch together at its corners the faces cancel
                    // and the normal is noise on either side; the outline is weighted to zero there.
                    if simd_dot(n[k], gpu.normals[k]) < 0.999 { differ += 1; if mesh.ink[k] > 0 { inked += 1 } }
                }
                #expect(worstP < 1e-5, "\(name) \(mesh.name): positions off by \(worstP)")
                #expect(Double(differ) < 0.01 * Double(p.count), "\(name) \(mesh.name): \(differ) normals differ")
                #expect(inked == 0, "\(name) \(mesh.name): \(inked) differing normals carry outline")
            }
        }
    }

    @Test func heldShapeCostsLittle() throws {
        let asset = try MouthRigTests.asset()
        let model = MouthModel(asset: asset)
        let start = Date()
        for i in 0..<120 { model.pose(MouthPose(J: Float(i % 30) / 30, wide: 0.3), dt: 1 / 60) }
        let perFrame = Date().timeIntervalSince(start) / 120
        print("mouth CPU per frame: \(String(format: "%.2f", perFrame * 1000)) ms")
        #expect(perFrame < 0.002)          // targets, springs and bone matrices only
    }
}
