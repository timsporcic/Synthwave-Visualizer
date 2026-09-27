import AppKit
import SwiftUI

@main struct SynthwaveApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var audio = AudioController()
    @State private var hud = DebugHUD()
    @State private var track = TrackTitleModel()

    var body: some Scene {
        Window("Synthwave", id: "visualizer") {
            ContentView(audio: audio, hud: hud, track: track)
                .task {
                    // Unit tests run inside this app; starting the tap there would raise the
                    // System Audio Recording prompt.
                    if !Self.isHostingTests { audio.start() }
                }
        }
        .commands {
            CommandGroup(before: .toolbar) {
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f")
                Toggle("Show Track Title", isOn: $track.isEnabled)
                    .keyboardShortcut("t")
                Divider()
            }
            CommandMenu("Source") {
                Picker("Source", selection: Binding(get: { audio.target }, set: { audio.select($0) })) {
                    ForEach(SourceMenuEntry.entries(sources: audio.sources, current: audio.target, name: Self.appName),
                            id: \.target) { entry in
                        Text(entry.isPlaying ? "\(entry.title)  ♪" : entry.title).tag(entry.target)
                    }
                }
                .pickerStyle(.inline)
            }
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

    final class AppDelegate: NSObject, NSApplicationDelegate {
        // The tap and the display-sleep assertion belong to the window; closing it ends both.
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }

    private static func appName(bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }
}
