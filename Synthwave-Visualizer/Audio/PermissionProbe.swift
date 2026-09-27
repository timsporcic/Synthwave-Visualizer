/// Tells a denied System Audio Recording permission apart from a paused track.
///
/// Denial shows up one of two ways: tap creation throws `.create`, or the tap is created and its
/// IOProc delivers exact zeros while the tapped process reports it is producing output.
nonisolated struct PermissionProbe {
    static let secondsToConclude = 3
    private var silentSecondsWhilePlaying = 0
    /// A denied tap never delivers a non-zero sample, so one is proof for the rest of the tap.
    private var proven = false

    /// Call once per second. `delivering` is whether the IOProc wrote samples in that second.
    /// Returns true once the tap has delivered exact silence for `secondsToConclude` consecutive
    /// seconds while its target was playing, and has never delivered real audio.
    mutating func record(exactSilence: Bool, targetPlaying: Bool, delivering: Bool) -> Bool {
        if delivering && !exactSilence { proven = true }
        guard !proven else { return false }
        silentSecondsWhilePlaying = exactSilence && targetPlaying && delivering ? silentSecondsWhilePlaying + 1 : 0
        return silentSecondsWhilePlaying >= Self.secondsToConclude
    }

    static func indicatesDenial(_ error: any Error) -> Bool {
        if case TapError.create = error { return true }
        return false
    }
}
