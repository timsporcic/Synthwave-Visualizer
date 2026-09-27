import CoreAudio

/// One Core Audio process object. A single app can own several (browser helper processes).
nonisolated struct AudioProcess: Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool

    static func readAll() throws -> [AudioProcess] {
        let ids = try CoreAudioProperty.readArray(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        // A process can exit between reading the list and reading its properties; skip it.
        return ids.compactMap { id in
            guard let pid = try? CoreAudioProperty.read(id, kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            let bundleID = (try? CoreAudioProperty.readString(id, kAudioProcessPropertyBundleID)) ?? ""
            let running = (try? CoreAudioProperty.read(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }
}

/// A picker entry: every audio process sharing one bundle ID.
nonisolated struct AudioSource: Hashable, Sendable, Identifiable {
    let bundleID: String
    let isPlaying: Bool
    var id: String { bundleID }
}

nonisolated extension Array where Element == AudioProcess {
    func objectIDs(matching bundleID: String) -> [AudioObjectID] {
        filter { $0.bundleID == bundleID }.map(\.objectID).sorted()
    }

    /// One entry per bundle ID, playing sources first so the one making sound is easy to find.
    func sources(excluding excludedBundleID: String?) -> [AudioSource] {
        let groups = Dictionary(grouping: filter { !$0.bundleID.isEmpty && $0.bundleID != excludedBundleID },
                                by: \.bundleID)
        return groups
            .map { AudioSource(bundleID: $0.key, isPlaying: $0.value.contains(where: \.isRunningOutput)) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.bundleID) < ($1.isPlaying ? 0 : 1, $1.bundleID) }
    }
}

/// Watches Core Audio's process list so a tap can follow its target across relaunches.
final class ProcessLocator {
    private let readProcesses: () -> [AudioProcess]
    private var watchers: [UUID: Watcher] = [:]
    private var listener: AudioObjectPropertyListenerBlock?

    private struct Watcher {
        let bundleID: String
        let continuation: AsyncStream<[AudioObjectID]>.Continuation
        var last: [AudioObjectID]
    }

    init(readProcesses: @escaping () -> [AudioProcess]) {
        self.readProcesses = readProcesses
    }

    /// A locator backed by the live process list, refreshed whenever Core Audio reports a change.
    static func live() -> ProcessLocator {
        let locator = ProcessLocator(readProcesses: { (try? AudioProcess.readAll()) ?? [] })
        locator.startListening()
        return locator
    }

    var processes: [AudioProcess] { readProcesses() }

    /// Yields the process object IDs for `bundleID` now, then again whenever that set changes.
    /// An empty array means no such process is running.
    func watch(bundleID: String) -> AsyncStream<[AudioObjectID]> {
        let (stream, continuation) = AsyncStream<[AudioObjectID]>.makeStream()
        let key = UUID()
        let current = readProcesses().objectIDs(matching: bundleID)
        watchers[key] = Watcher(bundleID: bundleID, continuation: continuation, last: current)
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.watchers[key] = nil }
        }
        return stream
    }

    func processListChanged() {
        guard !watchers.isEmpty else { return }
        let list = readProcesses()
        for (key, watcher) in watchers {
            let ids = list.objectIDs(matching: watcher.bundleID)
            guard ids != watcher.last else { continue }
            watchers[key]?.last = ids
            watcher.continuation.yield(ids)
        }
    }

    private func startListening() {
        // Delivered on the main queue, matching this type's main-actor isolation.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processListChanged() }
        }
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        let err = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        if err == noErr { listener = block }
    }

    isolated deinit {
        guard let listener else { return }
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
    }
}
