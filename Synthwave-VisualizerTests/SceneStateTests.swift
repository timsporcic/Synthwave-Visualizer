import Testing
@testable import Synthwave_Visualizer

private func features(bass: Float = 0, rms: Float = 0, beat: Bool = false) -> FrameFeatures {
    var f = FrameFeatures.silent
    f.bass = bass
    f.rms = rms
    f.beat = beat
    return f
}

struct SceneStateTests {
    @Test func gridScrollsAtBaseSpeedPlusAnRMSTermAndWraps() {
        var state = SceneState()
        state.advance(features(rms: 0.25), dt: 0.1)
        let expected = (SceneState.baseScrollSpeed + SceneState.rmsScrollSpeed * 0.25) * 0.1
        #expect(abs(state.gridOffset - expected) < 1e-6)
        for _ in 0..<100 { state.advance(features(rms: 1), dt: 0.1) }
        #expect(state.gridOffset >= 0 && state.gridOffset < 1)
    }

    @Test(arguments: [(60.0, 2), (120.0, 4), (30.0, 1)])
    func beatFlashLasts33Milliseconds(fps: Double, frames: Int) {
        var state = SceneState()
        var lit = 0
        state.advance(features(beat: true), dt: 1 / fps)
        if state.uniforms(width: 100, height: 100).cutShift > 0 { lit += 1 }
        for _ in 0..<10 {
            state.advance(features(), dt: 1 / fps)
            if state.uniforms(width: 100, height: 100).cutShift > 0 { lit += 1 }
        }
        #expect(lit == frames)
    }

    @Test func sunGrowsUpToEightPercentWithBass() {
        var state = SceneState()
        state.advance(features(bass: 0), dt: 1.0 / 60)
        #expect(abs(state.uniforms(width: 100, height: 100).sunRadius - 0.22) < 1e-6)
        state.advance(features(bass: 1), dt: 1.0 / 60)
        #expect(abs(state.uniforms(width: 100, height: 100).sunRadius - 0.22 * 1.08) < 1e-6)
    }

    @Test func chromaticAberrationIsAtMostFourPixels() {
        var state = SceneState()
        state.advance(features(bass: 1), dt: 1.0 / 60)
        #expect(state.uniforms(width: 100, height: 100).aberrationPixels == 4)
        state.advance(features(bass: 0.5), dt: 1.0 / 60)
        #expect(state.uniforms(width: 100, height: 100).aberrationPixels == 2)
    }
}
