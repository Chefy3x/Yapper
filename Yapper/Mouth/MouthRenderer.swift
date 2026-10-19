import Foundation
import Metal
import CoreGraphics
import simd

/// How the mouth is framed: an orthographic camera looking into the screen (Blender's +y), and the
/// head's turn. The defaults frame it the way the pill shows it: about 85 pt wide at rest in a
/// 160 × 100 pt view, with room below for the jaw to drop.
struct MouthFraming: Equatable, Sendable {
    /// World units across the view's width.
    var ortho: Float = 4.0
    /// Height of the view's centre, in world units.
    var centreZ: Float = -0.25
    /// The head: pitch, roll, yaw in degrees (Blender's XYZ Euler). The asset's own view is the rest.
    var rotationDegrees = SIMD3<Float>(4, 0, -5)
    /// Squash and stretch: + tall and narrow, - short and wide.
    var squash: Float = 0
}

/// The posed mouth for one frame: bone matrices from the rig, with follow-through. Cheap; the
/// renderer bends the meshes to them on the GPU.
final class MouthModel {
    let asset: MouthAsset
    let rig: MouthRig
    var followThrough: MouthFollowThrough
    private(set) var matrices: [simd_float4x4]

    init(asset: MouthAsset, springs: Float = 0.5) {
        self.asset = asset
        rig = MouthRig(asset)
        followThrough = MouthFollowThrough(strength: springs)
        matrices = rig.matrices(rig.targets(MouthPose()))
    }

    /// Moves the mouth to `pose`, `dt` seconds after the last one (0: snap there, no follow-through).
    func pose(_ pose: MouthPose, dt: Float) {
        var t = rig.targets(pose)
        if dt > 0 {
            let smear = followThrough.step(&t, rig: rig, dt: dt)
            matrices = rig.matrices(t, smear: smear)
        } else {
            followThrough.reset()
            matrices = rig.matrices(t)
        }
    }
}

/// Draws a `MouthModel` with Metal: skins the lips and hidden skin on the GPU, then draws cel-shaded
/// surfaces, holdout skin that leaves the pixel clear, and the ink outline as a pushed-out back-face
/// shell. Draws into whatever pass it's given (an on-screen drawable, or an offscreen texture).
final class MouthRenderer {
    static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    static let depthFormat = MTLPixelFormat.depth32Float

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sampleCount: Int
    private let pipeline: MTLRenderPipelineState
    private let skinPipeline: MTLComputePipelineState
    private let normalsPipeline: MTLComputePipelineState
    private let depth: MTLDepthStencilState
    private let asset: MouthAsset

    private struct Draw {
        var model: simd_float4x4
        var viewProj: simd_float4x4
        var light: SIMD4<Float>
        var misc: SIMD4<Float>
    }
    private struct Material {
        var params: SIMD4<Float>
        var bandAt: SIMD4<Float>
        var bandColor: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var bandTint: SIMD4<Float>
        var strokes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var strokeColor: SIMD4<Float>
        var color: SIMD4<Float>
    }

    /// What the GPU needs to bend one skinned mesh.
    private struct Skin {
        var weightStart: MTLBuffer, weightBone: MTLBuffer, weightValue: MTLBuffer
        var cornerStart: MTLBuffer, corners: MTLBuffer
        /// Bent positions and normals, one pair per frame in flight.
        var ring: [(positions: MTLBuffer, normals: MTLBuffer)]
    }
    private struct GPUMesh {
        var index: MTLBuffer
        var indexCount: Int
        var vertexCount: Int
        var positions: MTLBuffer
        var normals: MTLBuffer
        var hull: MTLBuffer
        var uv: MTLBuffer
        var ink: MTLBuffer
        var skin: Skin?
    }
    private var meshes: [GPUMesh] = []
    private var materials: [Material] = []
    private static let inFlight = 3
    private var frame = 0
    private let slots = DispatchSemaphore(value: MouthRenderer.inFlight)

    enum SetupError: Error { case noDevice, noShaders, noBuffer }

    init(asset: MouthAsset, device: MTLDevice? = MTLCreateSystemDefaultDevice(), sampleCount: Int = 4) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw SetupError.noDevice }
        self.device = device
        self.queue = queue
        self.asset = asset
        self.sampleCount = sampleCount
        let library = try device.makeLibrary(source: MouthShaders.source, options: nil)
        guard let vfn = library.makeFunction(name: "mouth_vertex"), let ffn = library.makeFunction(name: "mouth_fragment"),
              let skin = library.makeFunction(name: "mouth_skin"), let normals = library.makeFunction(name: "mouth_normals")
        else { throw SetupError.noShaders }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = Self.colorFormat
        pd.depthAttachmentPixelFormat = Self.depthFormat
        pd.rasterSampleCount = sampleCount
        pipeline = try device.makeRenderPipelineState(descriptor: pd)
        skinPipeline = try device.makeComputePipelineState(function: skin)
        normalsPipeline = try device.makeComputePipelineState(function: normals)
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { throw SetupError.noDevice }
        depth = ds

        func buffer<T>(_ a: [T]) throws -> MTLBuffer {
            let bytes = max(16, a.count * MemoryLayout<T>.stride)
            let b = a.isEmpty ? device.makeBuffer(length: bytes, options: .storageModeShared)
                              : a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let b else { throw SetupError.noBuffer }
            return b
        }
        for mesh in asset.meshes {
            var g = GPUMesh(index: try buffer(mesh.indices), indexCount: mesh.indices.count, vertexCount: mesh.positions.count,
                            positions: try buffer(mesh.positions), normals: try buffer(mesh.normals),
                            hull: try buffer(mesh.hullNormals), uv: try buffer(mesh.uvs), ink: try buffer(mesh.ink))
            if let w = mesh.weights {
                let (start, corners) = Self.corners(of: mesh)
                g.skin = Skin(weightStart: try buffer(w.start), weightBone: try buffer(w.bone), weightValue: try buffer(w.value),
                              cornerStart: try buffer(start), corners: try buffer(corners),
                              ring: try (0..<Self.inFlight).map { _ in (try buffer(mesh.positions), try buffer(mesh.normals)) })
            }
            meshes.append(g)
        }
        materials = asset.materials.map(Self.material)
    }

    /// For each vertex, the triangle corners it sits on (triangle × 3 + corner), as start offsets
    /// into one list.
    private static func corners(of mesh: MouthAsset.Mesh) -> ([UInt32], [UInt32]) {
        var count = [UInt32](repeating: 0, count: mesh.positions.count + 1)
        for v in mesh.indices { count[Int(v) + 1] += 1 }
        for i in 1..<count.count { count[i] += count[i - 1] }
        var fill = count
        var corners = [UInt32](repeating: 0, count: mesh.indices.count)
        for (k, v) in mesh.indices.enumerated() { corners[Int(fill[Int(v)])] = UInt32(k); fill[Int(v)] += 1 }
        return (count, corners)
    }

    private static func material(_ m: MouthAsset.Material) -> Material {
        let kind: Float = switch m.kind { case .flat: 0; case .cel: 1; case .holdout: 2 }
        var at = SIMD4<Float>(repeating: 0)
        var colors = [SIMD4<Float>](repeating: .zero, count: 4)
        for (i, b) in m.bands.prefix(4).enumerated() { at[i] = b.at; colors[i] = SIMD4(b.color, 1) }
        var strokes = [SIMD4<Float>](repeating: .zero, count: 4)
        for (i, s) in m.strokes.prefix(4).enumerated() { strokes[i] = s }
        return Material(params: SIMD4(kind, Float(min(4, m.bands.count)), Float(min(4, m.strokes.count)), m.band),
                        bandAt: at, bandColor: (colors[0], colors[1], colors[2], colors[3]),
                        bandTint: SIMD4(m.bandTint, m.strokeWidth),
                        strokes: (strokes[0], strokes[1], strokes[2], strokes[3]),
                        strokeColor: SIMD4(m.strokeColor, 1), color: SIMD4(m.color, 1))
    }

    // MARK: camera

    static func rotation(_ deg: SIMD3<Float>) -> simd_float4x4 {
        let r = deg * (.pi / 180)
        let (cy, sy) = (cos(r.y), sin(r.y)), (cz, sz) = (cos(r.z), sin(r.z))
        let ry = simd_float4x4(columns: (SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0), SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1)))
        let rz = simd_float4x4(columns: (SIMD4(cz, sz, 0, 0), SIMD4(-sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        return rz * ry * MouthRig.rotationX(r.x)                // Blender's XYZ Euler: X first
    }

    /// World (x right, y into the screen, z up) to Metal clip space, orthographic.
    static func viewProjection(_ f: MouthFraming, aspect: Float) -> simd_float4x4 {
        let halfW = f.ortho / 2, halfH = halfW / aspect
        let near: Float = -20, far: Float = 20                   // a depth range around the mouth
        return simd_float4x4(rows: [
            SIMD4(1 / halfW, 0, 0, 0),
            SIMD4(0, 0, 1 / halfH, -f.centreZ / halfH),
            SIMD4(0, 1 / (far - near), 0, -near / (far - near)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    // MARK: drawing

    /// Bends the skinned meshes to `model`'s bones into frame slot `slot`.
    private func encodeSkinning(_ model: MouthModel, slot: Int, into commands: MTLCommandBuffer) {
        guard let enc = commands.makeComputeCommandEncoder() else { return }
        var bones = model.matrices
        let bytes = bones.count * MemoryLayout<simd_float4x4>.stride
        for g in meshes {
            guard let skin = g.skin else { continue }
            var count = UInt32(g.vertexCount)
            let threads = MTLSize(width: g.vertexCount, height: 1, depth: 1)
            enc.setComputePipelineState(skinPipeline)
            enc.setBuffer(g.positions, offset: 0, index: 0)
            enc.setBuffer(skin.weightStart, offset: 0, index: 1)
            enc.setBuffer(skin.weightBone, offset: 0, index: 2)
            enc.setBuffer(skin.weightValue, offset: 0, index: 3)
            enc.setBytes(&bones, length: bytes, index: 4)
            enc.setBuffer(skin.ring[slot].positions, offset: 0, index: 5)
            enc.setBytes(&count, length: 4, index: 6)
            enc.dispatchThreads(threads, threadsPerThreadgroup: MTLSize(width: min(64, skinPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            enc.setComputePipelineState(normalsPipeline)
            enc.setBuffer(skin.ring[slot].positions, offset: 0, index: 0)
            enc.setBuffer(g.index, offset: 0, index: 1)
            enc.setBuffer(skin.cornerStart, offset: 0, index: 2)
            enc.setBuffer(skin.corners, offset: 0, index: 3)
            enc.setBuffer(skin.ring[slot].normals, offset: 0, index: 4)
            enc.setBytes(&count, length: 4, index: 5)
            enc.dispatchThreads(threads, threadsPerThreadgroup: MTLSize(width: min(64, normalsPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        enc.endEncoding()
    }

    /// Encodes the mouth into `pass` (colour cleared to transparent by the caller). Returns false,
    /// encoding nothing, when three frames are still in flight: it never blocks, because the
    /// main thread it draws on also carries the Yapper key's event tap.
    @discardableResult
    func encode(_ model: MouthModel, framing: MouthFraming, size: CGSize,
                pass: MTLRenderPassDescriptor, into commands: MTLCommandBuffer) -> Bool {
        guard slots.wait(timeout: .now()) == .success else { return false }
        let slot = frame % Self.inFlight
        frame += 1
        commands.addCompletedHandler { [slots] _ in slots.signal() }
        encodeSkinning(model, slot: slot, into: commands)

        guard let enc = commands.makeRenderCommandEncoder(descriptor: pass) else { return true }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depth)
        enc.setFrontFacing(.counterClockwise)
        let head = Self.rotation(framing.rotationDegrees)
            * simd_float4x4(diagonal: SIMD4(1 - 0.5 * framing.squash, 1, 1 + framing.squash, 1))   // as Blender scales the rig
        let vp = Self.viewProjection(framing, aspect: Float(size.width / max(1, size.height)))
        let light = SIMD4(asset.view.lightTowards, 0)

        func draw(_ i: Int, outline: Bool) {
            let mesh = asset.meshes[i], g = meshes[i]
            let bone = mesh.binding == .jaw ? model.matrices[model.rig.jawBone] : matrix_identity_float4x4
            var d = Draw(model: head * bone, viewProj: vp, light: light,
                         misc: SIMD4(outline ? (mesh.outline?.thickness ?? 0) : 0, asset.view.diffuse, asset.view.ambient, 0))
            let pos = g.skin?.ring[slot].positions ?? g.positions
            let nrm = g.skin?.ring[slot].normals ?? g.normals
            enc.setVertexBuffer(pos, offset: 0, index: 0)
            enc.setVertexBuffer(nrm, offset: 0, index: 1)
            // Blender's Solidify pushes bent lips out along their bent normals
            enc.setVertexBuffer(g.skin != nil ? nrm : g.hull, offset: 0, index: 2)
            enc.setVertexBuffer(g.uv, offset: 0, index: 3)
            enc.setVertexBuffer(g.ink, offset: 0, index: 4)
            enc.setVertexBytes(&d, length: MemoryLayout<Draw>.stride, index: 5)
            var m = materials[outline ? (mesh.outline?.material ?? mesh.material) : mesh.material]
            enc.setFragmentBytes(&m, length: MemoryLayout<Material>.stride, index: 0)
            enc.setFragmentBytes(&d, length: MemoryLayout<Draw>.stride, index: 1)
            enc.setCullMode(outline ? .front : .none)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: g.indexCount, indexType: .uint32,
                                      indexBuffer: g.index, indexBufferOffset: 0)
        }
        for i in asset.meshes.indices { draw(i, outline: false) }
        for i in asset.meshes.indices where asset.meshes[i].outline != nil { draw(i, outline: true) }
        enc.endEncoding()
        return true
    }

    /// The GPU's bent positions and normals for mesh `index` at `model`'s pose, read back: for tests.
    func skinned(_ model: MouthModel, mesh index: Int) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>])? {
        guard let skin = meshes[index].skin, let commands = queue.makeCommandBuffer() else { return nil }
        slots.wait()                                       // tests only: fine to wait here
        let slot = frame % Self.inFlight
        frame += 1
        commands.addCompletedHandler { [slots] _ in slots.signal() }
        encodeSkinning(model, slot: slot, into: commands)
        commands.commit()
        commands.waitUntilCompleted()
        let n = meshes[index].vertexCount
        func read(_ b: MTLBuffer) -> [SIMD3<Float>] {
            Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: SIMD3<Float>.self), count: n))
        }
        return (read(skin.ring[slot].positions), read(skin.ring[slot].normals))
    }

    /// Renders one frame offscreen at `width` × `height` pixels: for tests and still previews.
    func image(_ model: MouthModel, framing: MouthFraming, width: Int, height: Int) -> CGImage? {
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, storage: MTLStorageMode) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = storage
            return device.makeTexture(descriptor: d)
        }
        guard let msaa = texture(Self.colorFormat, samples: sampleCount, usage: .renderTarget, storage: .private),
              let resolved = texture(Self.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], storage: .shared),
              let depthTex = texture(Self.depthFormat, samples: sampleCount, usage: .renderTarget, storage: .private),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sampleCount > 1 ? msaa : resolved
        pass.colorAttachments[0].resolveTexture = sampleCount > 1 ? resolved : nil
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = sampleCount > 1 ? .multisampleResolve : .store
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        while !encode(model, framing: framing, size: CGSize(width: width, height: height), pass: pass, into: commands) {
            Thread.sleep(forTimeInterval: 0.002)           // offscreen only: wait for a free slot
        }
        commands.commit()
        commands.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolved.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
