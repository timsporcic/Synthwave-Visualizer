import SwiftUI

struct ContentView: View {
    let audio: AudioController
    let hud: DebugHUD

    var body: some View {
        VisualizerView(audio: audio, hud: hud)
            .ignoresSafeArea()
            .frame(minWidth: 640, minHeight: 360)
            .overlay(alignment: .topLeading) {
                if hud.isVisible { DebugHUDView(hud: hud, audio: audio).padding(8) }
            }
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
