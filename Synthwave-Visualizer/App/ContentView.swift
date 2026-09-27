import Accelerate
import SwiftUI

struct ContentView: View {
    let audio: AudioController

    var body: some View {
        VisualizerView()
            .ignoresSafeArea()
            .frame(minWidth: 640, minHeight: 360)
            .overlay(alignment: .topLeading) { DebugLabel(audio: audio).padding(8) }
            .alert("Tap Leak Check", isPresented: leakCheckShown) {
                Button("OK") { audio.leakCheckResult = nil }
            } message: {
                Text(audio.leakCheckResult ?? "")
            }
    }

    private var leakCheckShown: Binding<Bool> {
        Binding(get: { audio.leakCheckResult != nil }, set: { if !$0 { audio.leakCheckResult = nil } })
    }
}

/// Temporary Phase 3 check: RMS of the latest analysis window, computed on the main thread.
private struct DebugLabel: View {
    let audio: AudioController
    @State private var window = [Float](repeating: 0, count: AudioController.analysisWindow)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(verbatim: "\(audio.status)  rms \(String(format: "%.4f", rms()))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private func rms() -> Float {
        var window = window
        return window.withUnsafeMutableBufferPointer { buffer in
            audio.ring.readLatest(into: buffer.baseAddress!, count: buffer.count)
            return vDSP.rootMeanSquare(buffer)
        }
    }
}
