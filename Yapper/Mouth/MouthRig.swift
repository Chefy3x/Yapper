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
    /// The jaw moves a little to one side (world units, + right).
    var shift: Float = 0
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
        return MouthPose(J: J, wide: max(0, W), pucker: narrow * (1 - 0.5 * J), funnel: narrow * min(1, J * 1.4),
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
        /// The follow of the lower lip's mouth-edge bone at this point along the lip (an O seals to it).
        var followLower: Float
    }

    let hinge: SIMD3<Float>
    let jawMax: Float
    let wrapK: Float
    let upperLift: Float
    let ovalDrop: Float
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
        upperLift = asset.rig.upperLift
        ovalDrop = asset.rig.ovalDrop
        boneCount = asset.bones.count
        tune = asset.rig.tune
        let follows = Dictionary(asset.rig.nodes.map { ($0.name, $0.follow) }, uniquingKeysWith: { a, _ in a })
        nodes = asset.rig.nodes.map { n in
            let outer = n.name.hasPrefix("o")
            let base = outer ? String(n.name.dropFirst()) : n.name
            let side: Float = n.p.x < -1e-6 ? -1 : (n.p.x > 1e-6 ? 1 : 0)
            let lower = follows["d" + base.dropFirst()] ?? n.follow
            return Node(bone: n.bone, p: n.p, s: n.s, follow: n.follow, outer: outer,
                        top: base.hasPrefix("u"), bot: base.hasPrefix("d"), side: side, followLower: lower)
        }
        followD4 = asset.rig.nodes.first { $0.name == "d4" }?.follow ?? 0.68
    }

    func wrap(_ x: Float) -> Float { wrapK * x * x }

    func targets(_ q: MouthPose) -> MouthTargets {
        var J = q.J + 0.07 * q.fv * (1 - q.J)
        J = min(1.2, max(0, J))
        let u = Self.smooth(0.25, 1.0, J)
        let slide = SIMD3<Float>(q.shift, -0.09 * q.slide * u, -0.015 * q.slide * u)
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
            let seal = min(1, q.pucker + q.funnel) * (1 - Self.holeO(s))   // an O: the sides close, the middle opens
            if n.top {
                let uu = side != 0 ? q.upperUp[si] : 0.5 * (q.upperUp.x + q.upperUp.y)
                let h = Self.hole(s)
                off.z += kEdge * (c * (upperLift * J + 0.05 * q.part + 0.07 * uu + 0.02 * q.wide)
                                  + h * 0.05 * Self.smooth(0.4, 1.0, J)
                                  + Self.holeO(s) * (0.20 * q.pucker + 0.10 * q.funnel) * Self.smooth(0.05, 0.4, J))   // the O opens with the jaw
                off.z -= kEdge * c * 0.5 * q.close * dropAt(followD4)         // meet the lower lip halfway
                off.y += 0.06 * q.rollUpper * c; sy -= 0.25 * q.rollUpper * c; sz -= 0.3 * q.rollUpper * c
                off.z += kEdge * 0.11 * q.fv * c                              // F/V: show the front teeth
                off.z -= kEdge * seal * 0.5 * dropAt(n.followLower)
            }
            if n.bot {
                let ld = side != 0 ? q.lowerDown[si] : 0.5 * (q.lowerDown.x + q.lowerDown.y)
                off.z -= kEdge * (c * (0.06 * q.part + 0.07 * ld) + (0.5 * c + 0.5 * cw) * 0.05 * q.wide
                                  + Self.holeO(s) * 0.03 * (q.funnel + q.pucker) * Self.smooth(0.05, 0.4, J)
                                  + pow(Self.ellipse(s, 0.5), 0.7) * ovalDrop * Self.smooth(0.4, 1.1, J) + c * 0.05 * Self.smooth(0.15, 0.8, J))
                off.z += kEdge * c * 0.5 * q.close * dropAt(n.follow)        // press up to seal
                off.z += kEdge * seal * 0.5 * dropAt(n.followLower)
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
    /// The round hole of an O: wider, with the sides sealed.
    static func holeO(_ s: Float) -> Float { ellipse(s, 0.34) }

    static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.3 = SIMD4(v, 1); return m
    }
    static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }
    static func about(_ p: SIMD3<Float>, _ m: simd_float4x4) -> simd_float4x4 { translation(p) * m * translation(-p) }
}

/// Acting on top of the lip-sync, the way an animator would: the syllable that lands pops the
/// mouth a little further and lifts the upper lip off the teeth (a snarl, one side leading), the
/// corners drift into a smirk, the jaw shifts sideways, fast opens stretch the mouth tall and fast
/// closes squash it, and the head nods on accents. Each phrase picks its own lean, the head glances
/// now and then, and in a pause the mouth breathes and does one small thing every few seconds (a
/// lip press, a smirk, a tooth click, a part as if about to speak, a purse). A port of `Performer`
/// in tools/mouth/build_mouth.py; keep the two in step.
struct MouthPerformance: Sendable {
    struct Output: Sendable {
        var pose: MouthPose
        /// Added to the head's pitch, roll and yaw, in degrees.
        var head: SIMD3<Float>
        /// + stretches the mouth tall and narrow, - squashes it.
        var squash: Float
    }

    /// The small things a quiet mouth does.
    enum IdleAction: CaseIterable, Sendable {
        case press, smirk, click, part, purse
        var seconds: Float {
            switch self { case .press: 0.55; case .smirk: 1.4; case .click: 0.3; case .part: 1.0; case .purse: 0.9 }
        }
        /// Adds this action at strength `k` (0…1); `side` picks which corner leads.
        func apply(_ k: Float, side: Int, to p: inout MouthPose) {
            switch self {
            case .press: p.rollUpper += 0.6 * k; p.rollLower += 0.6 * k; p.J += 0.03 * k     // "mm"
            case .smirk:
                let one = side == 0 ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
                p.smile += 0.8 * k * one; p.upperUp += 0.25 * k * one
            case .click: p.J += 0.18 * k; p.part += 0.4 * k                                 // teeth tap
            case .part: p.J += 0.08 * k; p.part += 0.6 * k                                  // about to speak
            case .purse: p.pucker += 0.5 * k; p.J += 0.03 * k                               // hmm
            }
        }
    }

    private var t: Double = 0
    private var lastJ: Float = 0
    private var pop: Float = 0
    private var squashSpring = SIMD2<Float>(0, 0), nod = SIMD2<Float>(0, 0), tilt = SIMD2<Float>(0, 0)
    // pauses, phrases and glances
    private var rng = SplitMix(seed: 7)
    private var silentFor: Float = 9, quiet = SIMD2<Float>(1, 0), wasSpeaking = false
    private var nextAction: Float = 1.5, action: IdleAction?, actionT: Float = 0, lastAction: IdleAction?, actionSide = 0
    private var nextGlance: Float = 0.4, gaze = SIMD2<Float>(0, 0), gazeYaw = SIMD2<Float>(0, 0), gazePitch = SIMD2<Float>(0, 0)
    private var lean: Float = 0, leanSpring = SIMD2<Float>(0, 0), flip: Float = 1

    mutating func step(J: Float, W: Float, T: Float, dt: Float) -> Output {
        guard dt > 0 else { return Output(pose: .voice(J: J, W: W, T: T), head: .zero, squash: 0) }
        t += Double(dt)
        let speed = (J - lastJ) / dt
        lastJ = J
        if speed > 2.5 && J > 0.25 { pop = max(pop, min(1, (speed - 2.5) / 4)) }   // the syllable lands
        pop *= exp(-dt / 0.18)
        let side = Self.wander(t, 0.11, 0.27), smirk = Self.wander(t, 0.07, 0.19, 2)
        let snarl = min(1, 0.55 * J + 0.45 * pop)
        let narrow = max(0, -W), wide = max(0, W)
        var p = MouthPose()
        p.J = min(1.05, J + 0.08 * pop)                   // past ~1 the lower lip sags into a V
        p.wide = wide
        p.pucker = narrow * (1 - 0.5 * J)                  // eases as the jaw opens, but an O keeps its round
        p.funnel = narrow * min(1, J * 1.4)
        p.part = T * (1 - J)
        p.slide = 1
        p.upperUp = SIMD2(snarl * (1 + 0.35 * side), snarl * (1 - 0.35 * side))
        p.lowerDown = SIMD2(0.2 * J * (1 - 0.25 * side), 0.2 * J * (1 + 0.25 * side))
        p.smile = SIMD2(max(0, 0.12 + 0.18 * smirk) + 0.2 * wide, max(0, 0.12 - 0.18 * smirk) + 0.2 * wide)
        p.shift = 0.05 * side * min(1, J * 1.5)
        let nodDeg = Self.spring(&nod, 3 * pop - J, hz: 2.2, damping: 0.45, dt: dt)
        let tiltDeg = Self.spring(&tilt, 2.5 * smirk + 2 * pop * side, hz: 1.2, damping: 0.6, dt: dt)
        let squash = Self.spring(&squashSpring, max(-1, min(1, speed / 10)) * 0.09, hz: 3.5, damping: 0.35, dt: dt)

        // a pause: the voice has been quiet a moment (the reader fades the jaw shut at a phrase end)
        let speaking = J > 0.06
        silentFor = speaking ? 0 : silentFor + dt
        let q = min(1, max(0, Self.spring(&quiet, silentFor > 0.35 ? 1 : 0, hz: speaking ? 10 : 6, damping: 1, dt: dt)))
        if speaking && !wasSpeaking {                      // a new phrase picks its own lean
            if rng.uniform(0, 1) < 0.7 { flip = -flip }
            lean = flip * rng.uniform(0.4, 1)
        }
        wasSpeaking = speaking
        let leanNow = Self.spring(&leanSpring, lean, hz: 1, damping: 0.8, dt: dt)
        p.smile += SIMD2(0.18 * max(0, leanNow), 0.18 * max(0, -leanNow))
        // glances: a quick turn of the head, then it holds; half as often while talking
        nextGlance -= dt * (q > 0.5 ? 1 : 0.5)
        if nextGlance <= 0 {
            gaze = SIMD2(rng.uniform(-6, 6), rng.uniform(-2, 2.5))
            nextGlance = rng.uniform(3, 7)
        }
        let yaw = Self.spring(&gazeYaw, gaze.x, hz: 3.5, damping: 0.8, dt: dt)
        let pitch = Self.spring(&gazePitch, gaze.y, hz: 3.5, damping: 0.8, dt: dt)
        // breathing, and one small action at a time
        let breath = Float(sin(2 * Double.pi * 0.22 * t))
        p.J += q * 0.02 * (1 + breath)
        p.part += q * 0.12 * max(0, breath)
        if q > 0.8 && action == nil {
            nextAction -= dt
            if nextAction <= 0 {
                let choices = IdleAction.allCases.filter { $0 != lastAction }
                let next = choices[min(choices.count - 1, Int(rng.uniform(0, Float(choices.count))))]
                action = next; lastAction = next; actionT = 0
                actionSide = rng.uniform(0, 1) < 0.5 ? 0 : 1
            }
        }
        if let a = action {
            actionT += dt
            let u = min(1, max(0, actionT / a.seconds))
            let k = pow(sin(Float.pi * u), 2) * q
            a.apply(k, side: actionSide, to: &p)
            if actionT >= a.seconds { action = nil; nextAction = rng.uniform(2.5, 6) }
        }
        let head = SIMD3(0.6 * nodDeg + pitch, 0.6 * tiltDeg + 2 * leanNow, 1.2 * Self.wander(t, 0.05, 0.13, 4) + yaw)
        return Output(pose: p, head: head, squash: squash)
    }

    /// A smooth -1…1 drift from two unrelated slow waves.
    static func wander(_ t: Double, _ a: Double, _ b: Double, _ phase: Double = 0) -> Float {
        Float(0.6 * sin(2 * .pi * a * t + phase) + 0.4 * sin(2 * .pi * b * t + 1.7 * phase + 0.5))
    }

    private static func spring(_ s: inout SIMD2<Float>, _ goal: Float, hz: Float, damping z: Float, dt: Float) -> Float {
        let w0 = 2 * Float.pi * hz, h = dt / 4
        for _ in 0..<4 { s.y += (w0 * w0 * (goal - s.x) - 2 * z * w0 * s.y) * h; s.x += s.y * h }
        return s.x
    }
}

/// A small seeded random source, so the mouth's choices repeat run to run (and match the Python).
struct SplitMix: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in a…b.
    mutating func uniform(_ a: Float, _ b: Float) -> Float {
        a + (b - a) * Float(Double(next() >> 11) / 9_007_199_254_740_992)
    }
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
