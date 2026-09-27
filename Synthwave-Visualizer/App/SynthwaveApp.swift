import SwiftUI

@main struct SynthwaveApp: App {
    @State private var audio = AudioController()
    @State private var hud = DebugHUD()

    var body: some Scene {
        WindowGroup {
            ContentView(audio: audio, hud: hud)
                .task {
                    // Unit tests run inside this app; starting the tap there would raise the
                    // System Audio Recording prompt.
                    if !Self.isHostingTests { audio.start() }
                }
        }
        .commands {
            CommandMenu("Debug") {
                Toggle("Show Analyzer Overlay", isOn: $hud.isVisible)
                    .keyboardShortcut("d")
                Button("Run Tap Leak Check") { audio.runLeakCheck() }
            }
        }
    }

    nonisolated static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
