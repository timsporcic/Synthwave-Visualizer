/// Per-frame values the shaders read. Field order and all-Float layout must match `SceneUniforms`
/// in Shaders.swift.
nonisolated struct SceneUniforms {
    var width: Float
    var height: Float
    var time: Float
    /// Horizon, as a fraction of height from the top.
    var horizon: Float
    /// Sun radius as a fraction of height.
    var sunRadius: Float
    /// Cut-line offset in sun-radius units; nonzero for 33 ms after a beat.
    var cutShift: Float
    /// Grid scroll phase, 0..<1 of one line spacing.
    var gridOffset: Float
    var mids: Float
    var bass: Float
    var aberrationPixels: Float
    var bloomStrength: Float
}

/// Scene animation state, advanced once per frame. Everything is scaled by `dt` so the scene
/// moves at the same speed at any refresh rate.
nonisolated struct SceneState {
    static let horizon: Float = 0.62
    static let sunRadius: Float = 0.22
    static let sunBassGrowth: Float = 0.08
    /// Grid lines per second toward the camera, plus a term proportional to rms.
    static let baseScrollSpeed: Float = 0.5
    static let rmsScrollSpeed: Float = 2.5
    static let beatFlashSeconds = 0.033
    /// One cut-line width, in sun-radius units.
    static let cutLineShift: Float = 0.03
    static let maxAberrationPixels: Float = 4
    static let bloomStrength: Float = 0.6

    private(set) var time: Double = 0
    private(set) var gridOffset: Float = 0
    private var flashRemaining: Double = 0
    private var features = FrameFeatures.silent

    mutating func advance(_ features: FrameFeatures, dt: Double) {
        self.features = features
        time += dt
        gridOffset += (Self.baseScrollSpeed + Self.rmsScrollSpeed * features.rms) * Float(dt)
        gridOffset -= gridOffset.rounded(.down)
        flashRemaining -= dt
        if features.beat { flashRemaining = Self.beatFlashSeconds }
    }

    func uniforms(width: Int, height: Int) -> SceneUniforms {
        SceneUniforms(
            width: Float(width), height: Float(height),
            time: Float(time.truncatingRemainder(dividingBy: 3600)),
            horizon: Self.horizon,
            sunRadius: Self.sunRadius * (1 + Self.sunBassGrowth * features.bass),
            cutShift: flashRemaining > 0 ? Self.cutLineShift : 0,
            gridOffset: gridOffset,
            mids: features.mids,
            bass: features.bass,
            aberrationPixels: Self.maxAberrationPixels * features.bass,
            bloomStrength: Self.bloomStrength)
    }
}
