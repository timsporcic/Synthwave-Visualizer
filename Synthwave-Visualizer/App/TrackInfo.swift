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

    /// Parses the userInfo of Spotify's `com.spotify.client.PlaybackStateChanged` notification.
    init?(spotifyNotification info: [AnyHashable: Any]) {
        guard info["Player State"] as? String != "Stopped", let name = info["Name"] as? String else { return nil }
        title = name
        artist = info["Artist"] as? String ?? ""
    }
}

/// Follows Spotify's current track while enabled. Updates come from Spotify's playback
/// notification; one AppleScript read, off the main thread, fills in the track already playing
/// when the overlay is turned on. Off by default: that read raises the Automation prompt.
@Observable
final class TrackTitleModel {
    private(set) var track: TrackInfo?
    var isEnabled = false {
        didSet { isEnabled ? start() : stop() }
    }

    @ObservationIgnored private var observer: NSObjectProtocol?

    private func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let track = note.userInfo.flatMap(TrackInfo.init(spotifyNotification:))
            MainActor.assumeIsolated { self?.track = track }
        }
        readCurrentTrack()
    }

    private func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        track = nil
    }

    private func readCurrentTrack() {
        // Only when Spotify is running: compiling a script that names an app that isn't installed
        // raises a "Where is Spotify?" dialog.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return }
        Task.detached {
            let script = NSAppleScript(source: """
                with timeout of 2 seconds
                    tell application "Spotify"
                        if player state is not stopped then
                            return (name of current track) & linefeed & (artist of current track)
                        end if
                    end tell
                end timeout
                return ""
                """)
            var error: NSDictionary?
            let track = TrackInfo(scriptResult: script?.executeAndReturnError(&error).stringValue)
            await MainActor.run { [weak self] in
                guard let self, self.isEnabled, self.track == nil else { return }
                self.track = track
            }
        }
    }
}
