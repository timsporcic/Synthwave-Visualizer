import MetalKit
import QuartzCore

/// MTKViewDelegate: each frame, analyze the latest audio, advance the scene, and draw.
final class SynthwaveRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let scene: SceneRenderer
    private let audio: AudioController
    private let hud: DebugHUD
    private let analyzer: SpectrumAnalyzer
    private var state = SceneState()
    private var window = [Float](repeating: 0, count: AudioController.analysisWindow)
    private var lastFrameTime: CFTimeInterval?

    init?(view: MTKView, audio: AudioController, hud: DebugHUD) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            scene = try SceneRenderer(device: device, outputFormat: view.colorPixelFormat)
        } catch {
            assertionFailure("Scene shaders failed to build: \(error)")
            return nil
        }
        commandQueue = queue
        self.audio = audio
        self.hud = hud
        analyzer = SpectrumAnalyzer(sampleRate: audio.sampleRate)
        super.init()
        view.device = device
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime.map { now - $0 } ?? 1.0 / 60
        lastFrameTime = now

        // Analysis runs here, on the render clock, so audio and picture share one timeline.
        let features = analyzeLatest(dt: dt)
        if hud.isVisible { hud.features = features }
        state.advance(features, dt: dt)

        guard let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer() else { return }
        let output = drawable.texture
        scene.encode(into: buffer, output: output,
                     uniforms: state.uniforms(width: output.width, height: output.height), features: features)
        buffer.present(drawable)
        buffer.commit()
    }

    private func analyzeLatest(dt: Double) -> FrameFeatures {
        analyzer.setSampleRate(audio.sampleRate)
        return window.withUnsafeMutableBufferPointer { buffer in
            audio.ring.readLatest(into: buffer.baseAddress!, count: buffer.count)
            return analyzer.analyze(interleaved: buffer.baseAddress!, dt: dt)
        }
    }
}

/// Runs at the display's refresh rate (MTKView defaults to 60), follows the window to other
/// screens, and hides the cursor after two idle seconds.
final class SynthwaveMTKView: MTKView {
    private var screenObserver: NSObjectProtocol?
    private var cursorTimer: Timer?
    private var idleCursor = IdleCursor()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        guard let window else { return }
        matchRefreshRate()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.matchRefreshRate() }
        }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIdleCursor() }
        }
    }

    private func matchRefreshRate() {
        preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? 60
    }

    private func hideIdleCursor() {
        let mouse = NSEvent.mouseLocation
        guard idleCursor.shouldHide(mouseAt: mouse, now: CACurrentMediaTime()),
              let window, window.isKeyWindow, window.frame.contains(mouse) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
