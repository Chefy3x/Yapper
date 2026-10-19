import Foundation
import simd

/// What the mouth is doing, in the rig's anatomy channels. A straight port of `anat_targets` in
/// tools/mouth/build_mouth.py; keep the two in step (MouthRigTests checks them against Blender).
struct MouthPose: Equatable, Sendable {
    /// Jaw, 0 shut … 1 a big "ah" (about 11°), up to 1.2.
    var J: Float = 0
    var wide: Float = 0
    var pucker: Float = 0
    var funnel: Float = 0
    /// Lips part over closed teeth (s, t, ee).
    var part: Float = 0
    /// Lips seal over an open jaw (m, b, p).
    var close: Float = 0
    /// The jaw slides forward and down as it opens.
    var slide: Float = 0
    var rollUpper: Float = 0
    var rollLower: Float = 0
    /// Left, right.
    var smile = SIMD2<Float>(0, 0)
    var upperUp = SIMD2<Float>(0, 0)
    var lowerDown = SIMD2<Float>(0, 0)
    /// F/V: the lower lip tucks under the upper front teeth. The teeth never move for it.
    var fv: Float = 0

    /// From the voice reader's two Osipa channels plus teeth: jaw J, width W (negative is round),
    /// and T, teeth together (`from_voice`).
    static func voice(J: Float, W: Float, T: Float) -> MouthPose {
        let narrow = max(0, -W)
        return MouthPose(J: J, wide: max(0, W), pucker: narrow * (1 - J), funnel: narrow * min(1, J * 1.4),
                         part: T * (1 - J), slide: 1)
    }
}

/// Where every bone is heading for one pose: the jaw, plus six channels per lip bone (angle on the
/// hinge, offset x y z, scale y z).
struct MouthTargets: Sendable {
    var jaw: Float
    var slide: SIMD3<Float>
    /// Indexed by bone; lanes 0…5 are angle, ox, oy, oz, sy, sz. Root and jaw stay zero.
    var bones: [SIMD8<Float>]
}

/// The anatomy rig: turns a pose into bone targets and bone targets into skinning matrices. Upper
/// teeth ride the root (the head), lower teeth and tongue the jaw; only lip bones move freely.
struct MouthRig: Sendable {
    struct Node: Sendable {
        var bone: Int
        var p: SIMD3<Float>
        var s: Float
        var follow: Float
        var outer: Bool, top: Bool, bot: Bool
        var side: Float
    }

    let hinge: SIMD3<Float>
    let jawMax: Float
    let wrapK: Float
    let nodes: [Node]
    let boneCount: Int
    let jawBone = 1
    /// The lower lip's centre follow, used when the lips seal over an open jaw.
    let followD4: Float
    let tune: [Int: SIMD2<Float>]

    init(_ asset: MouthAsset) {
        hinge = asset.rig.hinge
        jawMax = asset.rig.jawMax
        wrapK = asset.rig.wrap
        boneCount = asset.bones.count
        tune = asset.rig.tune
        nodes = asset.rig.nodes.map { n in
            let outer = n.name.hasPrefix("o")
            let base = outer ? String(n.name.dropFirst()) : n.name
            let side: Float = n.p.x < -1e-6 ? -1 : (n.p.x > 1e-6 ? 1 : 0)
            return Node(bone: n.bone, p: n.p, s: n.s, follow: n.follow, outer: outer,
                        top: base.hasPrefix("u"), bot: base.hasPrefix("d"), side: side)
        }
        followD4 = asset.rig.nodes.first { $0.name == "d4" }?.follow ?? 0.68
    }

    func wrap(_ x: Float) -> Float { wrapK * x * x }

    func targets(_ q: MouthPose) -> MouthTargets {
        var J = q.J + 0.07 * q.fv * (1 - q.J)
        J = min(1.2, max(0, J))
        let u = Self.smooth(0.25, 1.0, J)
        let slide = SIMD3<Float>(0, -0.09 * q.slide * u, -0.015 * q.slide * u)
        let dropAt = { (f: Float) -> Float in 3.4 * sin(jawMax * J * f) }
        var bones = [SIMD8<Float>](repeating: .zero, count: boneCount)
        for n in nodes {
            let s = n.s, c = Self.centre(s), cw = 1 - Self.smooth(0, 0.3, min(s, 1 - s))
            let side = n.side, si = side < 0 ? 0 : 1
            let kEdge: Float = n.outer ? 0.5 : 1
            let smile = side != 0 ? q.smile[si] : 0.5 * (q.smile.x + q.smile.y)
            var off = SIMD3<Float>(side * cw * (0.12 * q.wide + 0.10 * smile - 0.30 * q.pucker - 0.18 * q.funnel),
                                   cw * (0.03 * q.wide - 0.08 * q.pucker - 0.04 * q.funnel) + c * (-0.12 * q.pucker - 0.07 * q.funnel),
                                   cw * (0.03 * q.wide + 0.07 * smile))
            off.y += wrap(n.p.x + off.x) - wrap(n.p.x)            // corners slide along the face
            var sy = 1 + 0.30 * q.pucker + 0.12 * q.funnel - 0.08 * q.wide
            var sz = 1 + 0.20 * q.pucker + 0.10 * q.funnel - 0.15 * q.wide
            if n.top {
                let uu = side != 0 ? q.upperUp[si] : 0.5 * (q.upperUp.x + q.upperUp.y)
                let h = Self.hole(s)
                off.z += kEdge * (c * (0.03 * J + 0.05 * q.part + 0.07 * uu + 0.02 * q.wide)
                                  + h * 0.05 * Self.smooth(0.4, 1.0, J)
                                  - pow(c, 1.5) * 0.11 * min(1, q.pucker + 0.6 * q.funnel))
                off.z -= kEdge * c * 0.5 * q.close * dropAt(followD4)         // meet the lower lip halfway
                off.y += 0.06 * q.rollUpper * c; sy -= 0.25 * q.rollUpper * c; sz -= 0.3 * q.rollUpper * c
                off.z += kEdge * 0.11 * q.fv * c                              // F/V: show the front teeth
            }
            if n.bot {
                let ld = side != 0 ? q.lowerDown[si] : 0.5 * (q.lowerDown.x + q.lowerDown.y)
                let h = Self.hole(s)
                off.z -= kEdge * (c * (0.06 * q.part + 0.07 * ld) + (0.5 * c + 0.5 * cw) * 0.05 * q.wide
                                  + h * (0.20 * q.funnel + 0.10 * q.pucker) - pow(c, 1.5) * 0.05 * min(1, q.pucker + q.funnel)
                                  + pow(h, 0.7) * 0.10 * Self.smooth(0.4, 1.1, J) + c * 0.05 * Self.smooth(0.15, 0.8, J))
                off.z += kEdge * c * 0.5 * q.close * dropAt(n.follow)        // press up to seal
                // the lower lip rolls out and fills as the jaw drops: its outer edge leads
                let round = q.pucker + q.funnel
                off.y -= (n.outer ? 0.08 : 0.04) * J * c + (n.outer ? 0.07 : 0.03) * round * c
                if !n.outer { sy *= 1 + 0.25 * J * c + 0.15 * round * c; sz *= 1 + 0.12 * J * c + 0.15 * round * c }
                off.y += 0.06 * q.rollLower * c; sy -= 0.25 * q.rollLower * c; sz -= 0.3 * q.rollLower * c
                // F/V: the lower lip rolls up and back behind the upper teeth, pressed flat
                let f = q.fv * c
                off.z += (n.outer ? 0 : 0.01) * f
                off.y += (n.outer ? 0.10 : 0.32) * f
                if !n.outer { sz *= 1 - 0.25 * f; sy *= 1 - 0.3 * f }
            }
            off += slide * n.follow / 0.72
            if n.outer { sy = 1; sz = 1 }
            bones[n.bone] = SIMD8(jawMax * J * n.follow, off.x, off.y, off.z, sy, sz, 0, 0)
        }
        return MouthTargets(jaw: J, slide: slide, bones: bones)
    }

    /// Skinning matrices, one per bone, in the rig's space. `smear` (per bone: stretch, shift) is
    /// the follow-through's squash on fast jaw moves.
    func matrices(_ t: MouthTargets, smear: [SIMD2<Float>]? = nil) -> [simd_float4x4] {
        var m = [simd_float4x4](repeating: matrix_identity_float4x4, count: boneCount)
        m[jawBone] = Self.translation(t.slide) * Self.about(hinge, Self.rotationX(jawMax * t.jaw))
        for n in nodes {
            var b = t.bones[n.bone]
            if let smear { b[5] *= 1 + smear[n.bone].x; b[3] += smear[n.bone].y }
            m[n.bone] = Self.translation(SIMD3(b[1], b[2], b[3]))
                * Self.about(hinge, Self.rotationX(b[0]))
                * Self.about(n.p, simd_float4x4(diagonal: SIMD4(1, b[4], b[5], 1)))
        }
        return m
    }

    // MARK: shared shapes

    static func smooth(_ e0: Float, _ e1: Float, _ v: Float) -> Float {
        let u = min(1, max(0, (v - e0) / (e1 - e0))); return u * u * (3 - 2 * u)
    }
    /// 0 at the corners … 1 in the middle of the lip.
    static func centre(_ s: Float) -> Float { smooth(0.17, 0.5, min(s, 1 - s)) }
    /// Elliptical falloff from the centre (Rigify's skin_jaw).
    static func ellipse(_ s: Float, _ reach: Float) -> Float {
        let x = abs(2 * s - 1) / reach; return sqrt(max(0, 1 - x * x))
    }
    /// A narrow bump at the centre: a round hole, not a slit.
    static func hole(_ s: Float) -> Float { ellipse(s, 0.24) }

    static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.3 = SIMD4(v, 1); return m
    }
    static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }
    static func about(_ p: SIMD3<Float>, _ m: simd_float4x4) -> simd_float4x4 { translation(p) * m * translation(-p) }
}

/// Follow-through on the lip bones: each channel trails its target through a damped spring, and
/// `strength` keeps part of the lag and overshoot (0 off, 1 full). Fast jaw moves add a smear. The
/// jaw and teeth never spring.
struct MouthFollowThrough: Sendable {
    var strength: Float
    private var x: [SIMD8<Float>] = []
    private var v: [SIMD8<Float>] = []
    private var lastJaw: Float = 0

    init(strength: Float) { self.strength = strength }

    mutating func reset() { x = []; v = []; lastJaw = 0 }

    /// Moves the springs on by `dt` towards `t`, rewrites `t` with where they are, and returns the
    /// smear per bone.
    mutating func step(_ t: inout MouthTargets, rig: MouthRig, dt: Float) -> [SIMD2<Float>] {
        var smear = [SIMD2<Float>](repeating: .zero, count: rig.boneCount)
        guard strength > 0, dt > 0 else { return smear }
        if x.isEmpty { x = t.bones; v = [SIMD8<Float>](repeating: .zero, count: t.bones.count) }
        let substeps = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Float(substeps)
        for (bone, fz) in rig.tune {
            let w0 = 2 * Float.pi * fz.x, k = w0 * w0, c = 2 * fz.y * w0
            let goal = t.bones[bone]
            var xb = x[bone], vb = v[bone]
            for _ in 0..<substeps { vb += (k * (goal - xb) - c * vb) * h; xb += vb * h }
            x[bone] = xb; v[bone] = vb
            t.bones[bone] = goal + strength * (xb - goal)
        }
        let speed = (t.jaw - lastJaw) / dt
        lastJaw = t.jaw
        let amount = strength * min(1, max(0, (abs(speed) - 4) / 4))
        if amount > 0 {
            let sign: Float = speed > 0 ? 1 : -1
            for n in rig.nodes where n.bot {
                let c = MouthRig.centre(n.s)
                smear[n.bone] = SIMD2(0.4 * amount * c, 0.05 * amount * sign * c)
            }
        }
        return smear
    }
}

/// Bends the lips and the hidden skin around the opening with the bones, the way Blender's
/// armature modifier does (weights normalised by their total), and recomputes their normals.
struct MouthSkinner {
    /// Skins `mesh` into `positions` and `normals` (resized to fit).
    static func skin(_ mesh: MouthAsset.Mesh, matrices: [simd_float4x4],
                     positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>]) {
        let n = mesh.positions.count
        if positions.count != n { positions = [SIMD3<Float>](repeating: .zero, count: n) }
        guard let w = mesh.weights else { positions = mesh.positions; normals = mesh.normals; return }
        mesh.positions.withUnsafeBufferPointer { rest in
            w.start.withUnsafeBufferPointer { start in
                w.bone.withUnsafeBufferPointer { bone in
                    w.value.withUnsafeBufferPointer { value in
                        matrices.withUnsafeBufferPointer { mats in
                            positions.withUnsafeMutableBufferPointer { out in
                                for i in 0..<n {
                                    let p = SIMD4<Float>(rest[i], 1)
                                    var acc = SIMD4<Float>.zero, total: Float = 0
                                    for k in Int(start[i])..<Int(start[i + 1]) {
                                        let wk = value[k]
                                        acc += wk * (mats[Int(bone[k])] * p)
                                        total += wk
                                    }
                                    out[i] = total > 1e-4 ? SIMD3(acc.x, acc.y, acc.z) / total : rest[i]
                                }
                            }
                        }
                    }
                }
            }
        }
        computeNormals(positions, indices: mesh.indices, into: &normals)
    }

    /// Smooth vertex normals weighted by each corner's angle, as Blender computes them.
    static func computeNormals(_ p: [SIMD3<Float>], indices: [UInt32], into normals: inout [SIMD3<Float>]) {
        if normals.count != p.count { normals = [SIMD3<Float>](repeating: .zero, count: p.count) }
        p.withUnsafeBufferPointer { p in
            indices.withUnsafeBufferPointer { idx in
                normals.withUnsafeMutableBufferPointer { nrm in
                    for i in 0..<nrm.count { nrm[i] = .zero }
                    var t = 0
                    while t + 2 < idx.count {
                        let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
                        t += 3
                        let ab = p[b] - p[a], ac = p[c] - p[a], bc = p[c] - p[b]
                        let face = simd_cross(ab, ac)
                        let len = simd_length(face)
                        guard len > 1e-12 else { continue }
                        let fn = face / len
                        nrm[a] += fn * angle(ab, ac)
                        nrm[b] += fn * angle(-ab, bc)
                        nrm[c] += fn * angle(-ac, -bc)
                    }
                    for i in 0..<nrm.count {
                        let l = simd_length(nrm[i]); if l > 1e-12 { nrm[i] /= l }
                    }
                }
            }
        }
    }

    private static func angle(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Float {
        let d = simd_dot(u, v) / max(1e-12, simd_length(u) * simd_length(v))
        return acos(min(1, max(-1, d)))
    }
}
