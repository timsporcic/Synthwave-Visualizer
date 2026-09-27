import MetalKit
import SwiftUI

struct VisualizerView: NSViewRepresentable {
    let audio: AudioController
    let hud: DebugHUD

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        context.coordinator.renderer = SynthwaveRenderer(view: view, audio: audio, hud: hud)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    final class Coordinator {
        var renderer: SynthwaveRenderer?
    }
}
