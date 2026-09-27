import simd

/// The plan's palette as linear 0...1 RGB. Grid and bars use cyan and magenta only;
/// orange and sunHighlight belong to the sun so it stays the focal point.
nonisolated enum Palette {
    static let background = rgb(0x0d0221)
    static let purple = rgb(0x8c1eff)
    static let magenta = rgb(0xff2975)
    static let hotPink = rgb(0xf222ff)
    static let orange = rgb(0xff901f)
    static let cyan = rgb(0x2de2e6)
    static let sunHighlight = rgb(0xffd319)

    private static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
    }
}
