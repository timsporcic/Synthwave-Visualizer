import CoreAudio
import Testing
@testable import Synthwave_Visualizer

private func process(_ id: AudioObjectID, _ bundleID: String, playing: Bool = false) -> AudioProcess {
    AudioProcess(objectID: id, pid: pid_t(id) + 1000, bundleID: bundleID, isRunningOutput: playing)
}

struct AudioProcessListTests {
    @Test func matchingReturnsEveryProcessWithTheBundleIDSorted() {
        let list = [process(9, "com.google.Chrome.helper"), process(3, "com.spotify.client"),
                    process(5, "com.google.Chrome.helper")]
        #expect(list.objectIDs(matching: "com.google.Chrome.helper") == [5, 9])
    }

    @Test func matchingReturnsEmptyWhenAbsent() {
        #expect([process(3, "com.apple.Music")].objectIDs(matching: "com.spotify.client").isEmpty)
    }

    @Test func sourcesGroupHelpersIntoOneEntryThatIsPlayingIfAnyProcessIs() {
        let list = [process(5, "com.google.Chrome.helper"), process(9, "com.google.Chrome.helper", playing: true)]
        #expect(list.sources(excluding: nil) == [AudioSource(bundleID: "com.google.Chrome.helper", isPlaying: true)])
    }

    @Test func sourcesSortPlayingFirstThenByBundleID() {
        let list = [process(1, "b.app"), process(2, "z.app", playing: true), process(3, "a.app")]
        #expect(list.sources(excluding: nil).map(\.bundleID) == ["z.app", "a.app", "b.app"])
    }

    @Test func sourcesSkipEmptyBundleIDsAndTheExcludedApp() {
        let list = [process(1, ""), process(2, "me.app"), process(3, "a.app")]
        #expect(list.sources(excluding: "me.app").map(\.bundleID) == ["a.app"])
    }
}

@MainActor
struct ProcessLocatorWatchTests {
    @Test func watchYieldsCurrentMatchThenOnlyChanges() async {
        var list = [process(3, "com.spotify.client")]
        let locator = ProcessLocator(readProcesses: { list })
        var updates = locator.watch(bundleID: "com.spotify.client").makeAsyncIterator()

        #expect(await updates.next() == [3])

        list.append(process(7, "com.apple.Music"))  // unrelated change: no yield
        locator.processListChanged()
        list = [process(8, "com.spotify.client")]  // Spotify relaunched with a new ID
        locator.processListChanged()
        #expect(await updates.next() == [8])

        list = []  // Spotify quit
        locator.processListChanged()
        #expect(await updates.next() == [])
    }

    @Test func liveProcessListReadsWithoutThrowing() throws {
        let processes = try AudioProcess.readAll()
        #expect(processes.allSatisfy { $0.pid > 0 })
    }
}
