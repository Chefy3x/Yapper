import Testing
import Foundation
import simd

/// The Swift rig against Blender: for each still pose, the lips, the hidden skin and a lower tooth
/// must land where Blender's armature put them (fixtures written by
/// `tools/mouth/build_mouth.py --export … --fixtures=YapperTests/Fixtures/Mouth`).
struct MouthRigTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("YapperTests/Fixtures/Mouth")

    static func asset() throws -> MouthAsset {
        try MouthAsset.load(repo.appendingPathComponent("Yapper/Resources/mouth.rig"))
    }

    struct Fixture {
        var step: Int
        var poses: [(name: String, pose: MouthPose, data: [String: [Float]])]
        var rigidRest: [Float]
    }

    static func fixture() throws -> Fixture {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("poses.json"))) as! [String: Any]
        let blob = try Data(contentsOf: fixtures.appendingPathComponent("poses.bin"))
        func floats(_ span: [String: Any]) -> [Float] {
            let off = span["offset"] as! Int, n = span["count"] as! Int
            return blob.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: off + $0 * 4, as: Float.self) } }
        }
        let poses = (json["poses"] as! [[String: Any]]).map { p -> (String, MouthPose, [String: [Float]]) in
            let a = p["args"] as! [String: Double]
            var q = MouthPose()
            q.J = Float(a["J"] ?? 0); q.wide = Float(a["wide"] ?? 0); q.pucker = Float(a["pucker"] ?? 0)
            q.funnel = Float(a["funnel"] ?? 0); q.part = Float(a["part"] ?? 0); q.close = Float(a["close"] ?? 0)
            q.slide = Float(a["slide"] ?? 0); q.fv = Float(a["fv"] ?? 0)
            let data = (p["data"] as! [String: [String: Any]]).mapValues(floats)
            return (p["name"] as! String, q, data)
        }
        return Fixture(step: json["step"] as! Int, poses: poses, rigidRest: floats(json["rigidRest"] as! [String: Any]))
    }

    @Test func assetLoads() throws {
        let a = try Self.asset()
        #expect(a.bones.prefix(2) == ["root", "jaw"])
        #expect(a.rig.nodes.count == a.bones.count - 2)
        #expect(a.meshes.contains { $0.name == "UpperLip" && $0.binding == .skinned && $0.outline != nil })
        #expect(a.meshes.filter { $0.binding == .jaw }.count == 6)      // five lower teeth and the tongue
        for m in a.meshes {
            #expect(m.positions.count == m.normals.count && m.positions.count == m.uvs.count)
            #expect(m.indices.allSatisfy { Int($0) < m.positions.count })
        }
    }

    @Test func lipsAndSkinMatchBlenderInEveryStill() throws {
        let asset = try Self.asset(), fx = try Self.fixture(), rig = MouthRig(asset)
        #expect(fx.poses.count == 8)
        for (name, pose, data) in fx.poses {
            let m = rig.matrices(rig.targets(pose))
            for object in ["UpperLip", "LowerLip", "SkinUpper", "SkinLower"] {
                let mesh = try #require(asset.mesh(named: object))
                var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
                MouthSkinner.skin(mesh, matrices: m, positions: &p, normals: &n)
                let want = try #require(data[object])
                var worst: Float = 0
                for (k, i) in stride(from: 0, to: p.count, by: fx.step).enumerated() {
                    let b = SIMD3(want[3 * k], want[3 * k + 1], want[3 * k + 2])
                    worst = max(worst, simd_distance(p[i], b))
                }
                #expect(worst < 1e-4, "\(name) \(object): off by \(worst)")
            }
        }
    }

    @Test func lowerTeethMoveOnlyWithTheJaw() throws {
        let asset = try Self.asset(), fx = try Self.fixture(), rig = MouthRig(asset)
        for (name, pose, data) in fx.poses {
            let jaw = rig.matrices(rig.targets(pose))[rig.jawBone]
            let want = try #require(data["LowerTooth2"])
            for k in 0..<(fx.rigidRest.count / 3) {
                let rest = SIMD4(fx.rigidRest[3 * k], fx.rigidRest[3 * k + 1], fx.rigidRest[3 * k + 2], 1)
                let got = jaw * rest
                let d = simd_distance(SIMD3(got.x, got.y, got.z), SIMD3(want[3 * k], want[3 * k + 1], want[3 * k + 2]))
                #expect(d < 1e-4, "\(name): lower tooth off by \(d)")
            }
        }
    }

    @Test func springsSettleOnTheTargetAndNeverTouchTheJaw() throws {
        let rig = MouthRig(try Self.asset())
        var follow = MouthFollowThrough(strength: 0.5)
        let goal = rig.targets(MouthPose(J: 0.8, wide: 0.3))
        var t = rig.targets(MouthPose())
        _ = follow.step(&t, rig: rig, dt: 1 / 60)
        var moved = false
        for _ in 0..<240 {
            t = goal
            _ = follow.step(&t, rig: rig, dt: 1 / 60)
            #expect(t.jaw == goal.jaw)
            if simd_length(t.bones[10] - goal.bones[10]) > 1e-3 { moved = true }
        }
        #expect(moved)                                                   // it lagged on the way
        for b in rig.nodes.map(\.bone) { #expect(simd_length(t.bones[b] - goal.bones[b]) < 1e-3) }
    }
}
