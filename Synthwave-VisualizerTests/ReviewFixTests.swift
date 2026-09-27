import CoreAudio
import Foundation
import Testing
@testable import Synthwave_Visualizer

struct StaleAudioTests {
    @Test func audioGoesStaleWhenNothingIsWrittenForAQuarterSecond() {
        var guardian = StaleAudio()
        let results = [(100, 0.0), (100, 0.2), (100, 0.3)].map { guardian.isStale(writeCount: $0.0, now: $0.1) }
        #expect(results == [false, false, true])
    }

    @Test func anyNewWriteMakesItFreshAgain() {
        var guardian = StaleAudio()
        _ = guardian.isStale(writeCount: 100, now: 0)
        _ = guardian.isStale(writeCount: 100, now: 1)
        let fresh = guardian.isStale(writeCount: 612, now: 1.01)
        #expect(!fresh)
    }

    @Test func ringReportsHowManySamplesWereWritten() {
        let ring = RingBuffer(capacity: 8)
        [Float](repeating: 1, count: 5).withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) }
        #expect(ring.writeCount == 5)
    }
}

struct PermissionProbeProofTests {
    @Test func anyRealAudioProvesPermissionForTheRestOfTheTap() {
        var probe = PermissionProbe()
        _ = probe.record(exactSilence: false, targetPlaying: true, delivering: true)
        let results = (0..<10).map { _ in probe.record(exactSilence: true, targetPlaying: true, delivering: true) }
        #expect(!results.contains(true))
    }

    @Test func silenceFromATapThatIsNotDeliveringIsNotDenial() {
        // A denied tap still runs its IOProc and delivers zeros. No samples at all means the
        // tap is not running, which is a different problem.
        var probe = PermissionProbe()
        let results = (0..<10).map { _ in probe.record(exactSilence: true, targetPlaying: true, delivering: false) }
        #expect(!results.contains(true))
    }
}

@MainActor
struct AudioControllerLifecycleTests {
    @Test func startIsIdempotent() {
        var reads = 0
        let controller = AudioController(locator: ProcessLocator(readProcesses: { reads += 1; return [] }))
        controller.start()
        let afterFirst = reads
        controller.start()
        #expect(reads == afterFirst)
    }
}

struct SpotifyNotificationTests {
    @Test func playingNotificationCarriesTitleAndArtist() {
        let info: [AnyHashable: Any] = ["Name": "Nightcall", "Artist": "Kavinsky", "Player State": "Playing"]
        #expect(TrackInfo(spotifyNotification: info) == TrackInfo(title: "Nightcall", artist: "Kavinsky"))
    }

    @Test func stoppedNotificationClearsTheTrack() {
        #expect(TrackInfo(spotifyNotification: ["Player State": "Stopped"]) == nil)
    }
}
