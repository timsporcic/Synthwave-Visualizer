import Accelerate
import CoreAudio
import Foundation
import Observation

/// Owns the tap and keeps it pointed at the selected source, restarting it when the source's
/// processes come and go (a Spotify relaunch changes its process object ID).
@Observable
final class AudioController {
    nonisolated enum Target: Hashable {
        case app(bundleID: String)
        case systemAudio

        static let spotify = Target.app(bundleID: "com.spotify.client")
    }

    enum Status: Equatable {
        case idle
        case waiting(bundleID: String)
        case running
        case failed(String)
    }

    /// Floats the analyzer reads per frame: 4096 stereo frames.
    static let analysisWindow = 8192

    private(set) var target: Target = .spotify
    private(set) var status: Status = .idle {
        didSet { status == .running ? displaySleep.hold() : displaySleep.release() }
    }
    /// Picker entries, refreshed once per second so the playing source sorts first.
    private(set) var sources: [AudioSource] = []
    private(set) var permissionDenied = false
    /// Set when the user closes the permission sheet, so detection does not reopen it every
    /// few seconds. Cleared whenever a source is (re)selected.
    var permissionSheetDismissed = false
    /// Result of the last Debug > Run Tap Leak Check, shown in an alert.
    var leakCheckResult: String?

    @ObservationIgnored let ring = RingBuffer(capacity: 16384)
    @ObservationIgnored private let tap: ProcessTap
    @ObservationIgnored private let displaySleep = DisplaySleepAssertion()
    @ObservationIgnored private let locator: ProcessLocator
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Timer?
    @ObservationIgnored private var probe = PermissionProbe()
    @ObservationIgnored private var tappedProcesses: [AudioObjectID] = []
    @ObservationIgnored private var scratch = [Float](repeating: 0, count: analysisWindow)

    init(locator: ProcessLocator = .live()) {
        self.locator = locator
        tap = ProcessTap(ring: ring)
    }

    /// The tap's sample rate, or 44.1 kHz until a tap has started.
    var sampleRate: Double { tap.format.mSampleRate > 0 ? tap.format.mSampleRate : 44100 }

    func start() {
        select(target)
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func select(_ newTarget: Target) {
        target = newTarget
        permissionSheetDismissed = false
        watchTask?.cancel()
        watchTask = nil
        stopTap()
        switch newTarget {
        case .systemAudio:
            startTap { try $0.startSystemAudio() }
        case .app(let bundleID):
            status = .waiting(bundleID: bundleID)
            let updates = locator.watch(bundleID: bundleID)
            watchTask = Task { [weak self] in
                for await ids in updates {
                    guard !Task.isCancelled, let self else { return }
                    self.follow(ids, bundleID: bundleID)
                }
            }
        }
    }

    private func follow(_ ids: [AudioObjectID], bundleID: String) {
        stopTap()
        guard !ids.isEmpty else {
            status = .waiting(bundleID: bundleID)
            return
        }
        tappedProcesses = ids
        startTap { try $0.start(processes: ids) }
    }

    private func startTap(_ body: (ProcessTap) throws -> Void) {
        probe = PermissionProbe()
        do {
            try body(tap)
            status = .running
            permissionDenied = false
        } catch {
            status = .failed(error.localizedDescription)
            if PermissionProbe.indicatesDenial(error) { permissionDenied = true }
        }
    }

    private func stopTap() {
        tap.stop()
        tappedProcesses = []
        if status == .running { status = .idle }
    }

    /// Phase 3 check: ten start/stop cycles must leave Core Audio's device count unchanged.
    func runLeakCheck() {
        guard status == .running else {
            leakCheckResult = "Start tapping a source first; the check cycles the current tap."
            return
        }
        let ids = tappedProcesses
        let restart: (ProcessTap) throws -> Void = switch target {
        case .systemAudio: { try $0.startSystemAudio() }
        case .app: { try $0.start(processes: ids) }
        }
        tap.stop()
        let before = Self.deviceCount()
        var failure: String?
        for _ in 0..<10 {
            do { try restart(tap) } catch { failure = error.localizedDescription }
            tap.stop()
        }
        let after = Self.deviceCount()
        startTap(restart)
        tappedProcesses = ids
        let verdict = before == after ? "PASS" : "FAIL"
        leakCheckResult = "\(verdict): \(before) devices before, \(after) after 10 cycles."
            + (failure.map { " A cycle failed: \($0)" } ?? "")
    }

    private static func deviceCount() -> Int {
        (try? CoreAudioProperty.readArray(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self).count) ?? -1
    }

    private func tick() {
        let processes = locator.processes
        sources = processes.sources(excluding: Bundle.main.bundleIdentifier)
        guard status == .running else { return }
        let silent = scratch.withUnsafeMutableBufferPointer { buffer in
            ring.readLatest(into: buffer.baseAddress!, count: buffer.count)
            return vDSP.maximumMagnitude(buffer) == 0
        }
        let playing = switch target {
        case .systemAudio: processes.contains(where: \.isRunningOutput)
        case .app: processes.contains { tappedProcesses.contains($0.objectID) && $0.isRunningOutput }
        }
        if probe.record(exactSilence: silent, targetPlaying: playing) {
            permissionDenied = true
        } else if !silent {
            permissionDenied = false
        }
    }
}
