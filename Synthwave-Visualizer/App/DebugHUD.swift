import SwiftUI

/// Debug overlay state. The renderer publishes each frame's features here only while visible.
@Observable
final class DebugHUD {
    var isVisible = false
    var features = FrameFeatures.silent
}

/// Plain-rectangle bar graph of the analyzer output, plus tap status. Toggle with ⌘D.
struct DebugHUDView: View {
    let hud: DebugHUD
    let audio: AudioController

    var body: some View {
        let f = hud.features
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                let width = size.width / CGFloat(f.bands.count)
                for (i, level) in f.bands.enumerated() {
                    let x = CGFloat(i) * width
                    let height = CGFloat(level) * size.height
                    context.fill(Path(CGRect(x: x + 1, y: size.height - height, width: width - 2, height: height)),
                                 with: .color(.cyan))
                    let peakY = size.height - CGFloat(f.peaks[i]) * size.height
                    context.fill(Path(CGRect(x: x + 1, y: peakY - 1, width: width - 2, height: 2)), with: .color(.pink))
                }
            }
            .frame(width: 320, height: 120)
            .background(.black.opacity(0.5))
            Text(verbatim: String(format: "bass %.2f  mids %.2f  rms %.4f", f.bass, f.mids, f.rms))
            HStack {
                Circle().fill(f.beat ? Color.pink : Color.gray.opacity(0.4)).frame(width: 10, height: 10)
                Text(verbatim: "\(audio.status)")
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.4), in: .rect(cornerRadius: 6))
    }
}
