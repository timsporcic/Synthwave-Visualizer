/// Tells a denied System Audio Recording permission apart from a paused track.
///
/// Denial shows up one of two ways: tap creation throws `.create`, or the tap is created and
/// delivers exact zeros while the tapped process reports it is producing output.
nonisolated struct PermissionProbe {
    static let secondsToConclude = 3
    private var silentSecondsWhilePlaying = 0

    /// Call once per second. Returns true once the tap has delivered exact silence for
    /// `secondsToConclude` consecutive seconds while its target was playing.
    mutating func record(exactSilence: Bool, targetPlaying: Bool) -> Bool {
        silentSecondsWhilePlaying = exactSilence && targetPlaying ? silentSecondsWhilePlaying + 1 : 0
        return silentSecondsWhilePlaying >= Self.secondsToConclude
    }

    static func indicatesDenial(_ error: any Error) -> Bool {
        if case TapError.create = error { return true }
        return false
    }
}
