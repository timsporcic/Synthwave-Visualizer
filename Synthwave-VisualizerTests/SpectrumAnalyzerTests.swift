import Foundation
import Testing
@testable import Synthwave_Visualizer

/// Test signals and a driver that feeds the analyzer the way the render loop does: every frame,
/// the latest 4096 stereo frames ending at the current time.
private enum Signal {
    static func sine(hz: Double, amplitude: Float = 1, seconds: Double, rate: Double = 44100) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// A frequency that falls exactly on an FFT bin, so the Hann window has no scalloping loss.
    static func binCentered(near hz: Double, rate: Double = 44100) -> Double {
        (hz * 4096 / rate).rounded() * rate / 4096
    }

    /// 120 BPM kick: a 60 Hz burst with a fast exponential decay every 0.5 s, starting at 0.25 s.
    static func kicks(seconds: Double, rate: Double = 44100) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        var onset = 0.25
        while onset < seconds {
            let start = Int(onset * rate)
            for i in 0..<Int(0.15 * rate) where start + i < out.count {
                let t = Double(i) / rate
                out[start + i] = Float(0.9 * exp(-t / 0.04) * sin(2 * .pi * 60 * t))
            }
            onset += 0.5
        }
        return out
    }

    static func noise(amplitude: Float, seconds: Double, rate: Double = 44100) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { _ in amplitude * Float.random(in: -1...1, using: &rng) }
    }
}

private func window(_ mono: [Float], endingAt end: Int) -> [Float] {
    var stereo = [Float](repeating: 0, count: 2 * SpectrumAnalyzer.fftSize)
    for i in 0..<SpectrumAnalyzer.fftSize {
        let source = end - SpectrumAnalyzer.fftSize + i
        let sample: Float = source >= 0 && source < mono.count ? mono[source] : 0
        stereo[2 * i] = sample
        stereo[2 * i + 1] = sample
    }
    return stereo
}

private func analyze(_ analyzer: SpectrumAnalyzer, _ stereo: [Float], dt: Double = 1.0 / 60) -> FrameFeatures {
    stereo.withUnsafeBufferPointer { analyzer.analyze(interleaved: $0.baseAddress!, dt: dt) }
}

/// Runs the analyzer over `mono` at `fps`, one frame per tick, like the render loop.
private func run(_ analyzer: SpectrumAnalyzer, _ mono: [Float], fps: Double, rate: Double = 44100) -> [FrameFeatures] {
    let frames = Int(Double(mono.count) / rate * fps)
    return (1...frames).map { frame in
        analyze(analyzer, window(mono, endingAt: Int(Double(frame) / fps * rate)), dt: 1 / fps)
    }
}

private func steady(_ mono: [Float]) -> [Float] { window(mono, endingAt: mono.count) }

struct SpectrumAnalyzerBandTests {
    @Test func bandEdgesAreSixteenLogSpacedBandsFrom40HzTo16kHz() {
        let edges = SpectrumAnalyzer.bandEdges
        #expect(edges.count == 17)
        #expect(abs(edges[0] - 40) < 1e-9)
        #expect(abs(edges[16] - 16000) < 1e-6)
        let ratios = zip(edges.dropFirst(), edges).map { $0 / $1 }
        #expect(ratios.allSatisfy { abs($0 - 1.4542) < 1e-3 })
    }

    @Test(arguments: [44100.0, 48000.0, 22050.0])
    func everyBandCoversAtLeastOneBin(rate: Double) {
        let bins = SpectrumAnalyzer(sampleRate: rate).bandBins
        #expect(bins.count == 16)
        #expect(bins.allSatisfy { $0.lowerBound >= 1 && $0.upperBound < SpectrumAnalyzer.fftSize / 2 })
        #expect(zip(bins, bins.dropFirst()).allSatisfy { $0.lowerBound <= $1.lowerBound })
    }
}

struct SpectrumAnalyzerLevelTests {
    @Test func fullScaleSineReadsZeroDecibels() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        let hz = Signal.binCentered(near: 1000)
        _ = analyze(analyzer, steady(Signal.sine(hz: hz, seconds: 0.2)))
        let band = SpectrumAnalyzer.band(containing: hz)
        #expect(abs(analyzer.rawBands[band] - 1) < 0.01)
    }

    @Test func minus20dBFSSineReadsThreeQuarters() {
        // -80...0 dB maps to 0...1, so -20 dB is 0.75.
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        let hz = Signal.binCentered(near: 1000)
        _ = analyze(analyzer, steady(Signal.sine(hz: hz, amplitude: 0.1, seconds: 0.2)))
        #expect(abs(analyzer.rawBands[SpectrumAnalyzer.band(containing: hz)] - 0.75) < 0.01)
    }

    @Test func zeroDecibelReferenceHoldsAt48kHz() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48000)
        let hz = Signal.binCentered(near: 1000, rate: 48000)
        _ = analyze(analyzer, steady(Signal.sine(hz: hz, seconds: 0.2, rate: 48000)))
        #expect(abs(analyzer.rawBands[SpectrumAnalyzer.band(containing: hz)] - 1) < 0.01)
    }

    @Test func sineEnergyStaysInItsOwnBand() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        let hz = Signal.binCentered(near: 1000)
        _ = analyze(analyzer, steady(Signal.sine(hz: hz, seconds: 0.2)))
        let own = SpectrumAnalyzer.band(containing: hz)
        for band in 0..<16 where abs(band - own) >= 2 {
            #expect(analyzer.rawBands[band] < 0.1, "band \(band)")
        }
    }

    @Test func silenceIsAllZero() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        let features = analyze(analyzer, [Float](repeating: 0, count: 8192))
        #expect(analyzer.rawBands.allSatisfy { $0 == 0 })
        #expect(features.bands.allSatisfy { $0 == 0 })
        #expect(features.rms == 0 && features.bass == 0 && features.mids == 0 && !features.beat)
    }

    @Test func rmsOfFullScaleSineIsOneOverRootTwo() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        let features = analyze(analyzer, steady(Signal.sine(hz: 1000, seconds: 0.2)))
        #expect(abs(features.rms - 0.7071) < 0.01)
    }

    @Test func bassFollowsLowToneAndMidsFollowMidTone() {
        let low = SpectrumAnalyzer(sampleRate: 44100)
        let lowFeatures = run(low, Signal.sine(hz: 70, seconds: 1), fps: 60).last!
        #expect(lowFeatures.bass > 0.5)
        #expect(lowFeatures.mids < 0.1)

        let mid = SpectrumAnalyzer(sampleRate: 44100)
        let midFeatures = run(mid, Signal.sine(hz: 700, seconds: 1), fps: 60).last!
        #expect(midFeatures.mids > 0.1)
        #expect(midFeatures.bass < 0.1)
    }
}

struct SpectrumAnalyzerSmoothingTests {
    private let hz = Signal.binCentered(near: 1000)
    private var band: Int { SpectrumAnalyzer.band(containing: hz) }

    @Test func firstFrameAttacksSeventyPercentOfTheWay() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        let features = analyze(analyzer, steady(Signal.sine(hz: hz, seconds: 0.2)))
        #expect(abs(features.bands[band] - 0.7) < 0.01)
    }

    @Test func levelsMatchAt30And60FramesPerSecond() {
        // Half a second of tone then half a second of silence, fed as whole windows so only the
        // smoothing (not where each frame rate samples the window transition) is compared.
        let tone = steady(Signal.sine(hz: hz, seconds: 0.2))
        let silence = [Float](repeating: 0, count: 8192)
        func drive(fps: Double) -> [FrameFeatures] {
            let analyzer = SpectrumAnalyzer(sampleRate: 44100)
            let half = Int(fps / 2)
            return (0..<(2 * half)).map { analyze(analyzer, $0 < half ? tone : silence, dt: 1 / fps) }
        }
        let at30 = drive(fps: 30), at60 = drive(fps: 60)
        for (i, slow) in at30.enumerated() {
            let fast = at60[2 * i + 1]  // same instant
            #expect(abs(slow.bands[band] - fast.bands[band]) < 1e-4, "frame \(i)")
            #expect(abs(slow.peaks[band] - fast.peaks[band]) < 0.07, "frame \(i)")
        }
    }

    @Test func barsFallSmoothlyToZeroAfterPause() {
        let signal = Signal.sine(hz: hz, seconds: 0.5) + [Float](repeating: 0, count: 44100)
        let frames = run(SpectrumAnalyzer(sampleRate: 44100), signal, fps: 60)
        let tail = frames[36...].map { $0.bands[band] }  // window fully past the tone by ~0.6 s
        #expect(zip(tail, tail.dropFirst()).allSatisfy { $1 <= $0 })
        #expect(tail.last! < 0.01)
    }

    @Test func peakHoldsForTwoTenthsThenFallsAt1Point8PerSecond() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        for _ in 0..<60 { _ = analyze(analyzer, steady(Signal.sine(hz: hz, seconds: 0.2))) }
        let silence = [Float](repeating: 0, count: 8192)
        let top = analyze(analyzer, silence).peaks[band]
        #expect(top > 0.99)
        var peaks: [Float] = []
        for _ in 0..<30 { peaks.append(analyze(analyzer, silence).peaks[band]) }
        #expect(peaks[9] == top)  // 10 frames in: 0.183 s, still holding
        // 0.5 s after the peak: about 0.3 s of falling at 1.8/s.
        #expect(abs(peaks[29] - (top - 0.3 * 1.8)) < 0.04)
    }
}

struct SpectrumAnalyzerBeatTests {
    @Test func kicksAt120BPMFireOneBeatEach() {
        let frames = run(SpectrumAnalyzer(sampleRate: 44100), Signal.kicks(seconds: 4), fps: 60)
        #expect(frames.filter(\.beat).count == 8)
    }

    @Test func beatCountIsTheSameAt120FramesPerSecond() {
        let frames = run(SpectrumAnalyzer(sampleRate: 44100), Signal.kicks(seconds: 4), fps: 120)
        #expect(frames.filter(\.beat).count == 8)
    }

    @Test func quietNoiseNeverFires() {
        let frames = run(SpectrumAnalyzer(sampleRate: 44100), Signal.noise(amplitude: 0.0005, seconds: 3), fps: 60)
        #expect(frames.filter(\.beat).isEmpty)
    }

    @Test func silenceNeverFires() {
        let frames = run(SpectrumAnalyzer(sampleRate: 44100), [Float](repeating: 0, count: 44100 * 2), fps: 60)
        #expect(frames.filter(\.beat).isEmpty)
    }

    @Test func steadyToneFiresAtMostOnceAtItsOnset() {
        let frames = run(SpectrumAnalyzer(sampleRate: 44100), Signal.sine(hz: 60, amplitude: 0.8, seconds: 3), fps: 60)
        #expect(frames.filter(\.beat).count <= 1)
    }
}

struct SpectrumAnalyzerPerformanceTests {
    @Test func analysisStaysUnderOneMillisecond() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        let stereo = window(Signal.noise(amplitude: 0.5, seconds: 0.2), endingAt: 8192)
        _ = analyze(analyzer, stereo)
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<200 { _ = analyze(analyzer, stereo) } }
        #expect(elapsed / 200 < .milliseconds(1), "\(elapsed / 200) per frame")
    }
}
