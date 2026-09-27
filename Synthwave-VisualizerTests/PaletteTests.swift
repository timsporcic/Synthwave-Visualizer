import Testing
@testable import Synthwave_Visualizer

struct PaletteTests {
    @Test func backgroundMatchesPlanHex() {
        // #0d0221
        #expect(Palette.background == SIMD3<Float>(13, 2, 33) / 255)
    }
}
