import CoreGraphics

/// Decides when to hide the cursor: once per stretch of two seconds without movement.
nonisolated struct IdleCursor {
    static let idleSeconds = 2.0
    private var lastLocation: CGPoint?
    private var lastMove = 0.0
    private var hidden = false

    mutating func shouldHide(mouseAt location: CGPoint, now: Double) -> Bool {
        if location != lastLocation {
            lastLocation = location
            lastMove = now
            hidden = false
            return false
        }
        guard !hidden, now - lastMove >= Self.idleSeconds else { return false }
        hidden = true
        return true
    }
}
