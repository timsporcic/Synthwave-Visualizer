import AppKit
import Observation

nonisolated struct TrackInfo: Equatable {
    let title: String
    let artist: String

    init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }

    /// Parses the AppleScript result: title, a line feed, then artist. Empty means nothing playing.
    init?(scriptResult: String?) {
        guard let scriptResult, !scriptResult.isEmpty else { return nil }
        let lines = scriptResult.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        title = String(lines[0])
        artist = lines.count > 1 ? String(lines[1]) : ""
    }
}

/// Reads Spotify's current track once per second while enabled. Off by default: the first read
/// raises macOS's Automation permission prompt.
@Observable
final class TrackTitleModel {
    private(set) var track: TrackInfo?
    var isEnabled = false {
        didSet { isEnabled ? start() : stop() }
    }

    @ObservationIgnored private var timer: Timer?
    // "is running" never launches Spotify; the timeout keeps a hung Spotify from blocking the UI.
    @ObservationIgnored private let script = NSAppleScript(source: """
        if application "Spotify" is running then
            with timeout of 1 second
                tell application "Spotify"
                    if player state is not stopped then
                        return (name of current track) & linefeed & (artist of current track)
                    end if
                end tell
            end timeout
        end if
        return ""
        """)

    private func start() {
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        track = nil
    }

    private func read() {
        var error: NSDictionary?
        track = TrackInfo(scriptResult: script?.executeAndReturnError(&error).stringValue)
    }
}
