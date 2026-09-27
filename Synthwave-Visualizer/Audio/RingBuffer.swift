import Synchronization

/// Fixed-size Float ring shared by the IOProc (the only writer) and the analyzer (the only reader).
///
/// `write` runs on Core Audio's realtime thread: it copies into preallocated storage and publishes
/// with atomic stores, with no allocation and no locks. `readLatest` takes a snapshot of the most
/// recent samples without consuming them, so there is no read index. If the reader is preempted
/// mid-copy long enough for the writer to lap it, it detects that seqlock-style and copies again.
nonisolated final class RingBuffer: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total samples ever written. Only grows; slot = index & mask.
    private let writeIndex = Atomic<Int>(0)
    /// End of the write in progress, published before its copy starts so a reader can tell
    /// whether its slots were overwritten while it was copying.
    private let reservedIndex = Atomic<Int>(0)

    /// `capacity` must be a power of two, and at least twice the largest `readLatest` count so
    /// the writer cannot lap the reader mid-copy.
    init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Total samples ever written. Stops advancing when the tap stops or stalls.
    var writeCount: Int { writeIndex.load(ordering: .acquiring) }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        // Only the last `capacity` samples of an oversized write can survive.
        let kept = min(count, capacity)
        let source = samples + (count - kept)
        let start = writeIndex.load(ordering: .relaxed) + (count - kept)
        reservedIndex.store(start + kept, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        copy(from: source, toSlot: start & mask, count: kept)
        writeIndex.store(start + kept, ordering: .releasing)
    }

    /// Copies the `count` most recent samples, oldest first, ending at the write index.
    /// Slots never written read as zero.
    func readLatest(into destination: UnsafeMutablePointer<Float>, count: Int) {
        precondition(count <= capacity)
        for _ in 0..<8 {
            let end = writeIndex.load(ordering: .acquiring)
            let available = min(count, end)
            let missing = count - available
            if missing > 0 { destination.update(repeating: 0, count: missing) }
            let oldest = end - available
            let slot = oldest & mask
            let firstRun = min(available, capacity - slot)
            (destination + missing).update(from: storage + slot, count: firstRun)
            (destination + missing + firstRun).update(from: storage, count: available - firstRun)
            // Intact unless a write reaching past oldest + capacity started during the copy.
            atomicMemoryFence(ordering: .acquiring)
            if reservedIndex.load(ordering: .relaxed) - oldest <= capacity { return }
        }
    }

    private func copy(from source: UnsafePointer<Float>, toSlot slot: Int, count: Int) {
        let firstRun = min(count, capacity - slot)
        (storage + slot).update(from: source, count: firstRun)
        storage.update(from: source + firstRun, count: count - firstRun)
    }
}
