import Foundation
import simd

/// The Loud Mouth's meshes, bone weights, materials and rig constants, exported from Blender by
/// `tools/mouth/build_mouth.py --export`. The Blender script is the art source; this is a straight
/// read of what it wrote. Positions are in the rig's own space with Blender's axes: x right, y into
/// the screen, z up.
///
/// File layout: "MRIG", UInt32 version, UInt32 header length, the JSON header, then little-endian
/// arrays the header points at (offsets from the end of the header, 4-byte aligned).
struct MouthAsset: Sendable {
    struct Material: Sendable {
        enum Kind: String, Sendable { case flat, cel, holdout }
        struct Band: Sendable { var at: Float; var color: SIMD3<Float> }
        var name: String
        var kind: Kind
        var color = SIMD3<Float>(0, 0, 0)
        /// Cel bands from dark to light: the brightness each one starts at, and its colour (linear).
        var bands: [Band] = []
        /// The lips' darker inner band: below this `t` the colour is multiplied by `bandTint`.
        var band: Float = 0
        var bandTint = SIMD3<Float>(1, 1, 1)
        /// Short curved crease strokes in (s, t): u0, v0, v1, bend.
        var strokes: [SIMD4<Float>] = []
        var strokeColor = SIMD3<Float>(0, 0, 0)
        var strokeWidth: Float = 0
    }

    enum Binding: Sendable, Equatable { case root, jaw, skinned }

    struct Weights: Sendable {
        /// Vertex i's influences are `bone[start[i]..<start[i+1]]` with matching `value`s.
        var start: [UInt32]
        var bone: [UInt16]
        var value: [Float]
    }

    struct Mesh: Sendable {
        var name: String
        var material: Int
        var binding: Binding
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        /// Smooth normals for pushing the outline out, so split corners stay joined.
        var hullNormals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        /// Outline thickness weight per vertex (the "ink" group): thick and thin lines.
        var ink: [Float]
        var indices: [UInt32]
        var weights: Weights?
        var outline: (thickness: Float, material: Int)?
    }

    struct Node: Sendable {
        var name: String
        var bone: Int
        var p: SIMD3<Float>
        var s: Float
        var follow: Float
    }

    struct Rig: Sendable {
        var hinge: SIMD3<Float>
        var jawMax: Float
        var wrap: Float
        var nodes: [Node]
        /// Follow-through per bone: spring frequency (Hz) and damping ratio.
        var tune: [Int: SIMD2<Float>]
    }

    struct View: Sendable {
        var rotationDegrees: SIMD3<Float>
        var lightTowards: SIMD3<Float>
        /// Brightness per unit of N·L from the sun (Blender: albedo / π).
        var diffuse: Float
        /// The world's faint even light, added on top.
        var ambient: Float
    }

    var bones: [String]
    var rig: Rig
    var view: View
    var materials: [Material]
    var meshes: [Mesh]

    enum LoadError: Error { case notARig, badHeader, outOfRange }

    static func load(_ url: URL) throws -> MouthAsset { try MouthAsset(data: Data(contentsOf: url)) }

    /// The copy shipped in the app.
    static func bundled() throws -> MouthAsset {
        guard let url = Bundle.main.url(forResource: "mouth", withExtension: "rig") else { throw LoadError.notARig }
        return try load(url)
    }

    init(data: Data) throws {
        guard data.count > 12, data.prefix(4) == Data("MRIG".utf8) else { throw LoadError.notARig }
        let headerLength = Int(data.u32(at: 8))
        guard data.count >= 12 + headerLength,
              let header = try JSONSerialization.jsonObject(with: data.subdata(in: 12..<12 + headerLength)) as? [String: Any]
        else { throw LoadError.badHeader }
        let blob = data.subdata(in: 12 + headerLength..<data.count)

        func floats(_ span: Any?) throws -> [Float] {
            guard let span = span as? [String: Any], let off = span["offset"] as? Int, let n = span["count"] as? Int,
                  off + n * 4 <= blob.count else { throw LoadError.outOfRange }
            return blob.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: off + $0 * 4, as: Float.self) } }
        }
        func u32s(_ span: Any?) throws -> [UInt32] {
            guard let span = span as? [String: Any], let off = span["offset"] as? Int, let n = span["count"] as? Int,
                  off + n * 4 <= blob.count else { throw LoadError.outOfRange }
            return blob.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: off + $0 * 4, as: UInt32.self) } }
        }
        func u16s(_ span: Any?) throws -> [UInt16] {
            guard let span = span as? [String: Any], let off = span["offset"] as? Int, let n = span["count"] as? Int,
                  off + n * 2 <= blob.count else { throw LoadError.outOfRange }
            return blob.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: off + $0 * 2, as: UInt16.self) } }
        }
        func vec3(_ v: Any?) -> SIMD3<Float> {
            let a = (v as? [Double]) ?? [0, 0, 0]
            return SIMD3(Float(a[0]), Float(a[1]), Float(a[2]))
        }
        func num(_ v: Any?) -> Float { Float((v as? Double) ?? 0) }

        guard let bones = header["bones"] as? [String],
              let rig = header["rig"] as? [String: Any], let ring = rig["ring"] as? [String: [String: Any]],
              let view = header["view"] as? [String: Any],
              let mats = header["materials"] as? [[String: Any]], let objs = header["objects"] as? [[String: Any]]
        else { throw LoadError.badHeader }
        self.bones = bones
        let boneIndex = Dictionary(uniqueKeysWithValues: bones.enumerated().map { ($1, $0) })

        var nodes: [Node] = []
        for (i, name) in bones.enumerated() where i >= 2 {
            guard let n = ring[name] else { throw LoadError.badHeader }
            nodes.append(Node(name: name, bone: i, p: vec3(n["p"]), s: num(n["s"]), follow: num(n["follow"])))
        }
        var tune: [Int: SIMD2<Float>] = [:]
        for (name, v) in (rig["tune"] as? [String: [Double]]) ?? [:] {
            if let b = boneIndex[name], v.count == 2 { tune[b] = SIMD2(Float(v[0]), Float(v[1])) }
        }
        self.rig = Rig(hinge: vec3(rig["hinge"]), jawMax: num(rig["jawMax"]), wrap: num(rig["wrap"]), nodes: nodes, tune: tune)
        self.view = View(rotationDegrees: vec3(view["rotationDeg"]), lightTowards: simd_normalize(vec3(view["lightTowards"])),
                         diffuse: num(view["diffuse"]), ambient: num(view["ambient"]))

        materials = mats.map { m in
            var out = Material(name: m["name"] as? String ?? "", kind: Material.Kind(rawValue: m["kind"] as? String ?? "") ?? .flat)
            out.color = vec3(m["color"])
            out.bands = ((m["bands"] as? [[String: Any]]) ?? []).map { Material.Band(at: num($0["at"]), color: vec3($0["color"])) }
            out.band = num(m["band"])
            if m["bandTint"] != nil { out.bandTint = vec3(m["bandTint"]) }
            out.strokes = ((m["strokes"] as? [[Double]]) ?? []).map { SIMD4(Float($0[0]), Float($0[1]), Float($0[2]), Float($0[3])) }
            out.strokeColor = vec3(m["strokeColor"])
            out.strokeWidth = num(m["strokeWidth"])
            return out
        }

        meshes = try objs.map { o in
            func v3s(_ key: String) throws -> [SIMD3<Float>] {
                let f = try floats(o[key]); return stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
            }
            let uv = try floats(o["uv"])
            var weights: Weights?
            if o["weightStart"] != nil {
                weights = Weights(start: try u32s(o["weightStart"]), bone: try u16s(o["weightBone"]), value: try floats(o["weightValue"]))
            }
            var outline: (Float, Int)?
            if let ol = o["outline"] as? [String: Any] { outline = (num(ol["thickness"]), ol["material"] as? Int ?? 0) }
            let binding: Binding = weights != nil ? .skinned : ((o["bind"] as? String) == "jaw" ? .jaw : .root)
            return Mesh(name: o["name"] as? String ?? "", material: o["material"] as? Int ?? 0, binding: binding,
                        positions: try v3s("position"), normals: try v3s("normal"), hullNormals: try v3s("hullNormal"),
                        uvs: stride(from: 0, to: uv.count, by: 2).map { SIMD2(uv[$0], uv[$0 + 1]) },
                        ink: try floats(o["ink"]), indices: try u32s(o["index"]), weights: weights, outline: outline)
        }
    }

    func mesh(named name: String) -> Mesh? { meshes.first { $0.name == name } }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
