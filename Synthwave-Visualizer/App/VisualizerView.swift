import MetalKit
import SwiftUI

struct VisualizerView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        context.coordinator.renderer = SynthwaveRenderer(view: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    final class Coordinator {
        var renderer: SynthwaveRenderer?
    }
}
