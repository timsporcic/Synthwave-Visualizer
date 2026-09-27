/// Everything the renderer needs from one analysis frame.
nonisolated struct FrameFeatures: Sendable, Equatable {
    /// Smoothed band levels, 0...1, lowest band first.
    var bands: [Float]
    /// Peak-hold level per band, 0...1.
    var peaks: [Float]
    /// Mean smoothed level of the bands centered 40 to 120 Hz.
    var bass: Float
    /// Mean smoothed level of the bands centered 200 Hz to 2 kHz.
    var mids: Float
    /// RMS of the raw mono window.
    var rms: Float
    var beat: Bool

    static let silent = FrameFeatures(
        bands: Array(repeating: 0, count: SpectrumAnalyzer.bandCount),
        peaks: Array(repeating: 0, count: SpectrumAnalyzer.bandCount),
        bass: 0, mids: 0, rms: 0, beat: false)
}
