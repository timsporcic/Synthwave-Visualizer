import IOKit.pwr_mgt

/// Keeps the display awake while held.
nonisolated final class DisplaySleepAssertion {
    private var id = IOPMAssertionID(0)
    private(set) var isHeld = false

    func hold() {
        guard !isHeld else { return }
        isHeld = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Synthwave visualizer is running" as CFString, &id) == kIOReturnSuccess
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        isHeld = false
    }

    deinit { release() }
}
