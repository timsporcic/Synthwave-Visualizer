/// Notices when the ring stops receiving samples (tap stopped, target quit, device stalled), so
/// the analyzer can be fed silence and the bars decay instead of freezing on the last window.
nonisolated struct StaleAudio {
    static let staleAfterSeconds = 0.25
    private var lastWriteCount: Int?
    private var lastChange = 0.0

    mutating func isStale(writeCount: Int, now: Double) -> Bool {
        if writeCount != lastWriteCount {
            lastWriteCount = writeCount
            lastChange = now
            return false
        }
        return now - lastChange > Self.staleAfterSeconds
    }
}
