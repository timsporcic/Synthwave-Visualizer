import MetalKit
import QuartzCore

final class SynthwaveRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let audio: AudioController
    private let hud: DebugHUD
    private let analyzer: SpectrumAnalyzer
    private var window = [Float](repeating: 0, count: AudioController.analysisWindow)
    private var lastFrameTime: CFTimeInterval?

    init?(view: MTKView, audio: AudioController, hud: DebugHUD) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue
        self.audio = audio
        self.hud = hud
        analyzer = SpectrumAnalyzer(sampleRate: audio.sampleRate)
        super.init()
        view.device = device
        let bg = Palette.background
        view.clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let features = analyzeLatest()
        if hud.isVisible { hud.features = features }

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Analysis runs here, on the render clock, so audio and picture share one timeline.
    private func analyzeLatest() -> FrameFeatures {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime.map { now - $0 } ?? 1.0 / 60
        lastFrameTime = now
        analyzer.setSampleRate(audio.sampleRate)
        return window.withUnsafeMutableBufferPointer { buffer in
            audio.ring.readLatest(into: buffer.baseAddress!, count: buffer.count)
            return analyzer.analyze(interleaved: buffer.baseAddress!, dt: dt)
        }
    }
}
