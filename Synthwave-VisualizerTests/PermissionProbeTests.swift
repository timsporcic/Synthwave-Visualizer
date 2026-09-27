import Testing
@testable import Synthwave_Visualizer

struct PermissionProbeTests {
    @Test func threeSilentSecondsWhileTheTargetPlaysMeansDenied() {
        var probe = PermissionProbe()
        let results = (0..<3).map { _ in probe.record(exactSilence: true, targetPlaying: true, delivering: true) }
        #expect(results == [false, false, true])
    }

    @Test func silenceWhileTheTargetIsPausedIsNotDenial() {
        var probe = PermissionProbe()
        let results = (0..<10).map { _ in probe.record(exactSilence: true, targetPlaying: false, delivering: true) }
        #expect(!results.contains(true))
    }

    @Test func realAudioResetsTheCount() {
        var probe = PermissionProbe()
        _ = probe.record(exactSilence: true, targetPlaying: true, delivering: true)
        _ = probe.record(exactSilence: true, targetPlaying: true, delivering: true)
        _ = probe.record(exactSilence: false, targetPlaying: true, delivering: true)
        let afterReset = probe.record(exactSilence: true, targetPlaying: true, delivering: true)
        #expect(!afterReset)
    }

    @Test func tapCreationFailureMeansDenied() {
        #expect(PermissionProbe.indicatesDenial(TapError.create(-1)))
        #expect(!PermissionProbe.indicatesDenial(TapError.aggregate(-1)))
    }
}

struct TestHostTests {
    @Test func appKnowsItIsHostingTestsSoItNeverStartsTheTap() {
        #expect(SynthwaveApp.isHostingTests)
    }
}
