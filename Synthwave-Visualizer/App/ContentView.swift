import AppKit
import SwiftUI

struct ContentView: View {
    let audio: AudioController
    let hud: DebugHUD
    let track: TrackTitleModel

    var body: some View {
        VisualizerView(audio: audio, hud: hud)
            .ignoresSafeArea()
            .frame(minWidth: 640, minHeight: 360)
            .overlay(alignment: .topLeading) {
                if hud.isVisible { DebugHUDView(hud: hud, audio: audio).padding(8) }
            }
            .overlay(alignment: .bottom) {
                if track.isEnabled, let info = track.track { TrackOverlay(track: info).padding(.bottom, 40) }
            }
            .sheet(isPresented: permissionSheetShown) { PermissionSheet(audio: audio) }
            .alert("Tap Leak Check", isPresented: leakCheckShown) {
                Button("OK") { audio.leakCheckResult = nil }
            } message: {
                Text(audio.leakCheckResult ?? "")
            }
    }

    private var permissionSheetShown: Binding<Bool> {
        Binding(get: { audio.permissionDenied && !audio.permissionSheetDismissed },
                set: { if !$0 { audio.permissionSheetDismissed = true } })
    }

    private var leakCheckShown: Binding<Bool> {
        Binding(get: { audio.leakCheckResult != nil }, set: { if !$0 { audio.leakCheckResult = nil } })
    }
}

private struct PermissionSheet: View {
    let audio: AudioController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Audio Recording is off").font(.headline)
            Text("""
                The visualizer needs permission to hear the app it listens to. Turn on \
                System Audio Recording for Synthwave-Visualizer in System Settings > \
                Privacy & Security, then try again.
                """)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("Try Again") { audio.select(audio.target) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct TrackOverlay: View {
    let track: TrackInfo

    var body: some View {
        VStack(spacing: 6) {
            Text(track.title.uppercased())
                .font(.system(size: 30, weight: .heavy, design: .monospaced))
                .foregroundStyle(Palette.color(Palette.hotPink))
            Text(track.artist.uppercased())
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.color(Palette.cyan))
        }
        .tracking(3)
        .shadow(color: Palette.color(Palette.hotPink).opacity(0.9), radius: 8)
        .shadow(color: Palette.color(Palette.cyan).opacity(0.5), radius: 16)
        .multilineTextAlignment(.center)
    }
}

extension Palette {
    static func color(_ rgb: SIMD3<Float>) -> Color {
        Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}
