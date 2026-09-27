import CoreGraphics
import Testing
@testable import Synthwave_Visualizer

struct IdleCursorTests {
    private func run(_ samples: [(CGPoint, Double)]) -> [Bool] {
        var idle = IdleCursor()
        return samples.map { idle.shouldHide(mouseAt: $0.0, now: $0.1) }
    }

    @Test func hidesAfterTwoSecondsWithoutMovement() {
        let p = CGPoint(x: 1, y: 1)
        #expect(run([(p, 0), (p, 1.9), (p, 2.1)]) == [false, false, true])
    }

    @Test func hidesOncePerIdleStretch() {
        #expect(run([(.zero, 0), (.zero, 2.5), (.zero, 3.0)]) == [false, true, false])
    }

    @Test func movementRestartsTheTimer() {
        let moved = CGPoint(x: 5, y: 0)
        #expect(run([(.zero, 0), (.zero, 2.5), (moved, 3.0), (moved, 4.9), (moved, 5.1)])
                == [false, true, false, false, true])
    }
}

struct SourceMenuTests {
    private let names: (String) -> String = { $0.uppercased() }

    @Test func spotifyThenSystemAudioThenOtherSources() {
        let entries = SourceMenuEntry.entries(
            sources: [AudioSource(bundleID: "com.apple.Music", isPlaying: true),
                      AudioSource(bundleID: "com.spotify.client", isPlaying: false)],
            current: .spotify, name: names)
        #expect(entries.map(\.target) == [.spotify, .systemAudio, .app(bundleID: "com.apple.Music")])
        #expect(entries[2].isPlaying)
        #expect(entries[2].title == "COM.APPLE.MUSIC")
    }

    @Test func spotifyShowsPlayingFromItsSource() {
        let entries = SourceMenuEntry.entries(
            sources: [AudioSource(bundleID: "com.spotify.client", isPlaying: true)], current: .spotify, name: names)
        #expect(entries[0].isPlaying)
        #expect(entries[0].title == "Spotify")
    }

    @Test func currentTargetStaysListedAfterItsProcessExits() {
        let entries = SourceMenuEntry.entries(sources: [], current: .app(bundleID: "gone.app"), name: names)
        #expect(entries.map(\.target) == [.spotify, .systemAudio, .app(bundleID: "gone.app")])
    }
}

struct DisplaySleepAssertionTests {
    @Test func holdsUntilReleased() {
        let assertion = DisplaySleepAssertion()
        #expect(!assertion.isHeld)
        assertion.hold()
        #expect(assertion.isHeld)
        assertion.hold()  // idempotent
        assertion.release()
        #expect(!assertion.isHeld)
    }
}

struct TrackInfoTests {
    @Test func parsesTitleAndArtistLines() {
        #expect(TrackInfo(scriptResult: "Nightcall\nKavinsky") == TrackInfo(title: "Nightcall", artist: "Kavinsky"))
    }

    @Test func emptyResultMeansNothingPlaying() {
        #expect(TrackInfo(scriptResult: "") == nil)
        #expect(TrackInfo(scriptResult: nil) == nil)
    }
}
