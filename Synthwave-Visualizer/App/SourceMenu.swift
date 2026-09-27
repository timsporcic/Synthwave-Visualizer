/// One item in the Source menu.
nonisolated struct SourceMenuEntry: Hashable {
    let target: AudioController.Target
    let title: String
    let isPlaying: Bool

    /// Spotify first, then System Audio, then every other app with an audio process (playing
    /// first). The current target stays listed after its process exits so its checkmark shows.
    static func entries(sources: [AudioSource], current: AudioController.Target,
                        name: (String) -> String) -> [SourceMenuEntry] {
        let spotifyID = "com.spotify.client"
        var entries = [
            SourceMenuEntry(target: .spotify, title: "Spotify",
                            isPlaying: sources.contains { $0.bundleID == spotifyID && $0.isPlaying }),
            SourceMenuEntry(target: .systemAudio, title: "System Audio", isPlaying: false),
        ]
        entries += sources.filter { $0.bundleID != spotifyID }.map {
            SourceMenuEntry(target: .app(bundleID: $0.bundleID), title: name($0.bundleID), isPlaying: $0.isPlaying)
        }
        if case .app(let bundleID) = current, !entries.contains(where: { $0.target == current }) {
            entries.append(SourceMenuEntry(target: current, title: name(bundleID), isPlaying: false))
        }
        return entries
    }
}
