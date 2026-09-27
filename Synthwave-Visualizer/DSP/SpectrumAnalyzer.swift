import Accelerate

/// Turns the latest 4096 stereo frames into `FrameFeatures`. Runs once per rendered frame on the
/// render clock. Every time constant is scaled by the frame's `dt`, so the result looks the same
/// at 60 Hz and 120 Hz.
nonisolated final class SpectrumAnalyzer {
    static let fftSize = 4096
    static let bandCount = 16
    /// 17 edges of 16 log-spaced bands from 40 Hz to 16 kHz.
    static let bandEdges: [Double] = (0...bandCount).map { 40 * pow(16000.0 / 40, Double($0) / Double(bandCount)) }

    // Easing per 60 Hz frame, converted with k = 1 - (1 - k60)^(dt * 60).
    static let attack: Float = 0.7
    static let decay: Float = 0.12
    static let peakHoldSeconds = 0.2
    static let peakFallPerSecond: Float = 1.8
    static let floorDecibels: Float = -80

    // Beat detection runs on linear bass energy.
    static let beatRatio: Float = 1.4
    /// Energy of one -50 dBFS bin.
    static let beatFloor: Float = 1e-5
    static let beatMinimumGap = 0.13
    static let beatAverageSeconds = 1.0

    private static let bassBands = bands(centeredIn: 40...120)
    private static let midBands = bands(centeredIn: 200...2000)

    private(set) var sampleRate: Double
    /// FFT bins feeding each band. Every band has at least one.
    private(set) var bandBins: [ClosedRange<Int>] = []
    /// Unsmoothed band levels from the last frame, 0...1 over -80...0 dBFS.
    private(set) var rawBands = [Float](repeating: 0, count: bandCount)
    private var bassEnergyBins = 0..<0

    private var levels = [Float](repeating: 0, count: bandCount)
    private var peaks = [Float](repeating: 0, count: bandCount)
    private var peakHolds = [Double](repeating: 0, count: bandCount)
    private var bassEnergyAverage: Float = 0
    private var secondsSinceBeat = Double.infinity
    /// A beat fires once per excursion above the threshold; energy must drop back below it
    /// before the next one, so a sustained bass note fires only at its onset.
    private var beatArmed = true

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var mono = [Float](repeating: 0, count: fftSize)
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    private var normalized = [Float](repeating: 0, count: fftSize / 2)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
    private let imag = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: Self.fftSize, isHalfWindow: false)
        computeBins()
    }

    deinit {
        real.deallocate()
        imag.deallocate()
    }

    func setSampleRate(_ rate: Double) {
        guard rate != sampleRate else { return }
        sampleRate = rate
        computeBins()
    }

    static func band(containing hz: Double) -> Int {
        min(max((bandEdges.lastIndex { $0 <= hz } ?? 0), 0), bandCount - 1)
    }

    /// `interleaved` holds 2 * fftSize floats: the latest stereo frames, oldest first.
    func analyze(interleaved: UnsafePointer<Float>, dt rawDT: Double) -> FrameFeatures {
        let dt = min(max(rawDT, 0), 0.1)  // a stalled frame should not make bars jump
        let n = Self.fftSize

        // 1. Mix to mono
        mono.withUnsafeMutableBufferPointer { m in
            vDSP_vadd(interleaved, 2, interleaved + 1, 2, m.baseAddress!, 1, vDSP_Length(n))
        }
        vDSP.multiply(0.5, mono, result: &mono)
        let rms = vDSP.rootMeanSquare(mono)

        // 2. Hann window
        vDSP.multiply(mono, window, result: &windowed)

        // 3. Real FFT: pack even samples into real, odd into imag, transform in place. The
        // output is packed too: imag[0] holds Nyquist, so bin 0 is never read.
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withUnsafeBufferPointer { w in
            w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
            }
        }
        fft.forward(input: split, output: &split)
        vDSP.absolute(split, result: &magnitudes)

        // 4. vDSP's real FFT is 2x the mathematical DFT and the Hann window's coherent gain is
        // 0.5, so this scale makes a full-scale sine read 1.0 (0 dBFS).
        vDSP.multiply(1 / (Float(n) * 0.5), magnitudes, result: &magnitudes)
        let bassEnergy = magnitudes[bassEnergyBins].reduce(0) { $0 + $1 * $1 }

        vDSP.clip(magnitudes, to: pow(10, Self.floorDecibels / 20)...Float.greatestFiniteMagnitude, result: &normalized)
        vDSP.convert(amplitude: normalized, toDecibels: &normalized, zeroReference: 1)
        vDSP.add(-Self.floorDecibels, normalized, result: &normalized)
        vDSP.multiply(1 / -Self.floorDecibels, normalized, result: &normalized)
        vDSP.clip(normalized, to: 0...1, result: &normalized)

        // 5. Bands: max level in each band's bins
        for (band, bins) in bandBins.enumerated() {
            rawBands[band] = vDSP.maximum(normalized[bins])
        }

        // 6. Smoothing and peak hold
        let frames = Float(dt * 60)
        let attackK = 1 - pow(1 - Self.attack, frames)
        let decayK = 1 - pow(1 - Self.decay, frames)
        for band in 0..<Self.bandCount {
            let target = rawBands[band]
            levels[band] += (target - levels[band]) * (target > levels[band] ? attackK : decayK)
            if levels[band] >= peaks[band] {
                peaks[band] = levels[band]
                peakHolds[band] = Self.peakHoldSeconds
            } else if peakHolds[band] > 0 {
                peakHolds[band] -= dt
            } else {
                peaks[band] = max(levels[band], peaks[band] - Self.peakFallPerSecond * Float(dt))
            }
        }

        // 7-8. Scalars and beat
        let bass = Self.bassBands.reduce(0) { $0 + levels[$1] } / Float(Self.bassBands.count)
        let mids = Self.midBands.reduce(0) { $0 + levels[$1] } / Float(Self.midBands.count)
        secondsSinceBeat += dt
        var beat = false
        if bassEnergy > Self.beatRatio * bassEnergyAverage && bassEnergy > Self.beatFloor {
            if beatArmed && secondsSinceBeat >= Self.beatMinimumGap {
                beat = true
                beatArmed = false
                secondsSinceBeat = 0
            }
        } else {
            beatArmed = true
        }
        bassEnergyAverage += (bassEnergy - bassEnergyAverage) * Float(1 - exp(-dt / Self.beatAverageSeconds))

        // 9. Publish
        return FrameFeatures(bands: levels, peaks: peaks, bass: bass, mids: mids, rms: rms, beat: beat)
    }

    private func computeBins() {
        let binHz = sampleRate / Double(Self.fftSize)
        let lastBin = Self.fftSize / 2 - 1
        func clamp(_ bin: Int) -> Int { min(max(bin, 1), lastBin) }
        bandBins = (0..<Self.bandCount).map { band in
            let low = clamp(Int((Self.bandEdges[band] / binHz).rounded(.up)))
            let high = clamp(Int((Self.bandEdges[band + 1] / binHz).rounded(.up)) - 1)
            if low <= high { return low...high }
            // Narrower than one bin: use the bin nearest the band's center.
            let center = clamp(Int((Self.bandCenter(band) / binHz).rounded()))
            return center...center
        }
        let bassLow = clamp(Int((40 / binHz).rounded(.up)))
        let bassHigh = clamp(Int((120 / binHz).rounded(.up)) - 1)
        bassEnergyBins = bassLow..<(bassHigh + 1)
    }

    private static func bandCenter(_ band: Int) -> Double {
        (bandEdges[band] * bandEdges[band + 1]).squareRoot()
    }

    private static func bands(centeredIn range: ClosedRange<Double>) -> [Int] {
        (0..<bandCount).filter { range.contains(bandCenter($0)) }
    }
}
