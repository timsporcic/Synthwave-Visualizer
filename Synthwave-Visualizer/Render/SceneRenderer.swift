import Metal

enum RendererError: Error {
    case missingFunction(String)
    case resourceCreation
}

/// Draws one synthwave frame into any output texture: scene into an RGBA16Float target, then
/// bloom at half resolution and a composite pass into `output`.
final class SceneRenderer {
    private let device: MTLDevice
    private let scenePipeline: MTLRenderPipelineState
    private let barPipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var sceneTexture: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?

    init(device: MTLDevice, outputFormat: MTLPixelFormat) throws {
        self.device = device
        let library = try device.makeLibrary(source: ShaderSource.source, options: nil)
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return f
        }
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: Bool = false) throws
            -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = try function(vertex)
            desc.fragmentFunction = try function(fragment)
            desc.colorAttachments[0].pixelFormat = format
            if blend {
                let a = desc.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        scenePipeline = try pipeline("fullscreenVertex", "sceneFragment", format: .rgba16Float)
        barPipeline = try pipeline("barVertex", "barFragment", format: .rgba16Float, blend: true)
        brightPipeline = try pipeline("fullscreenVertex", "brightPass", format: .rgba16Float)
        blurPipeline = try pipeline("fullscreenVertex", "blur", format: .rgba16Float)
        compositePipeline = try pipeline("fullscreenVertex", "composite", format: outputFormat)
    }

    func encode(into buffer: MTLCommandBuffer, output: MTLTexture, uniforms: SceneUniforms, features: FrameFeatures) {
        guard let scene = texture(&sceneTexture, width: output.width, height: output.height),
              let bloomA = texture(&bloomA, width: max(output.width / 2, 1), height: max(output.height / 2, 1)),
              let bloomB = texture(&bloomB, width: max(output.width / 2, 1), height: max(output.height / 2, 1))
        else { return }
        var u = uniforms
        var levels = features.bands + features.peaks

        pass(buffer, target: scene) { e in
            e.setRenderPipelineState(scenePipeline)
            e.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.setRenderPipelineState(barPipeline)
            e.setVertexBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            e.setVertexBytes(&levels, length: MemoryLayout<Float>.stride * levels.count, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 64)
        }
        pass(buffer, target: bloomA) { e in
            e.setRenderPipelineState(brightPipeline)
            e.setFragmentTexture(scene, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        for (source, target, direction) in [(bloomA, bloomB, SIMD2<Float>(1, 0)), (bloomB, bloomA, SIMD2<Float>(0, 1))] {
            var direction = direction
            pass(buffer, target: target) { e in
                e.setRenderPipelineState(blurPipeline)
                e.setFragmentTexture(source, index: 0)
                e.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        pass(buffer, target: output) { e in
            e.setRenderPipelineState(compositePipeline)
            e.setFragmentTexture(scene, index: 0)
            e.setFragmentTexture(bloomA, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    private func pass(_ buffer: MTLCommandBuffer, target: MTLTexture, _ body: (MTLRenderCommandEncoder) -> Void) {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: desc) else { return }
        body(encoder)
        encoder.endEncoding()
    }

    /// Returns `cached` if it already has this size, otherwise a new RGBA16Float render target.
    private func texture(_ cached: inout MTLTexture?, width: Int, height: Int) -> MTLTexture? {
        if let t = cached, t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        cached = device.makeTexture(descriptor: desc)
        return cached
    }
}
