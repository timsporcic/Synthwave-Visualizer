import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import Testing
import UniformTypeIdentifiers
@testable import Synthwave_Visualizer

/// Renders frames offscreen and inspects pixels. Set SYNTHWAVE_SNAPSHOT_DIR (pass it to
/// xcodebuild as TEST_RUNNER_SYNTHWAVE_SNAPSHOT_DIR) to also write PNGs for a visual check.
@MainActor
struct SceneRendererTests {
    nonisolated static let width = 640, height = 360

    struct Image {
        let pixels: [UInt8]  // BGRA
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * SceneRendererTests.width + x) * 4
            return SIMD3(Float(pixels[i + 2]), Float(pixels[i + 1]), Float(pixels[i])) / 255
        }
        func meanDifference(_ other: Image) -> Float {
            let sum = zip(pixels, other.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            return Float(sum) / Float(pixels.count) / 255
        }
    }

    static func features(bands: Float, bass: Float, mids: Float, rms: Float, beat: Bool) -> FrameFeatures {
        FrameFeatures(bands: Array(repeating: bands, count: 16), peaks: Array(repeating: min(bands + 0.1, 1), count: 16),
                      bass: bass, mids: mids, rms: rms, beat: beat)
    }

    static let silence = FrameFeatures.silent
    static let pad = features(bands: 0.45, bass: 0.2, mids: 0.6, rms: 0.2, beat: false)
    static let kick = FrameFeatures(
        bands: (0..<16).map { $0 < 4 ? 0.95 : 0.3 }, peaks: (0..<16).map { $0 < 4 ? 1 : 0.4 },
        bass: 1, mids: 0.3, rms: 0.6, beat: true)

    func render(_ features: FrameFeatures, name: String) throws -> Image {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(device: device, outputFormat: .bgra8Unorm)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: desc))
        var state = SceneState()
        state.advance(features, dt: 1.0 / 60)
        let queue = try #require(device.makeCommandQueue())
        let buffer = try #require(queue.makeCommandBuffer())
        renderer.encode(into: buffer, output: output,
                        uniforms: state.uniforms(width: Self.width, height: Self.height), features: features)
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        output.getBytes(&pixels, bytesPerRow: Self.width * 4,
                        from: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0)
        let image = Image(pixels: pixels)
        if let dir = ProcessInfo.processInfo.environment["SYNTHWAVE_SNAPSHOT_DIR"] {
            try writePNG(pixels, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return image
    }

    func writePNG(_ bgra: [UInt8], to url: URL) throws {
        let provider = try #require(CGDataProvider(data: Data(bgra) as CFData))
        let image = try #require(CGImage(
            width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func shaderLibraryCompilesAndBuildsEveryPipeline() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = try SceneRenderer(device: device, outputFormat: .bgra8Unorm)
    }

    @Test func topOfSkyIsTheBackgroundColor() throws {
        let image = try render(Self.silence, name: "silence")
        let top = image.rgb(Self.width / 2, 2)
        #expect(simd_distance(top, Palette.background) < 0.06, "\(top)")
    }

    @Test func skyJustAboveTheHorizonIsOrange() throws {
        let image = try render(Self.silence, name: "silence")
        let c = image.rgb(Self.width / 20, Int(0.61 * Double(Self.height)))
        #expect(c.x > 0.7 && c.x > c.y && c.y > c.z, "\(c)")
    }

    @Test func sunIsBrightAboveTheHorizonCenter() throws {
        let image = try render(Self.silence, name: "silence")
        let c = image.rgb(Self.width / 2, Int((0.62 - 0.22 * 0.75) * Double(Self.height)))
        #expect(c.x > 0.8, "\(c)")
    }

    @Test func gridDrawsCyanLinesBelowTheHorizon() throws {
        let image = try render(Self.silence, name: "silence")
        var cyan = 0
        for y in Int(0.7 * Double(Self.height))..<Self.height {
            for x in 0..<Self.width {
                let c = image.rgb(x, y)
                if c.z > 0.5 && c.y > 0.5 && c.x < 0.5 * c.z { cyan += 1 }
            }
        }
        #expect(cyan > 500, "\(cyan) cyan pixels")
    }

    @Test func gridFadesIntoTheHorizonInsteadOfFormingASolidBand() throws {
        // Where horizontal lines are closer together than a few pixels, they must fade out
        // rather than pile up into a bright cyan slab. Bars off (their caps are legitimately
        // cyan), mids high since mids drive grid brightness.
        let image = try render(Self.features(bands: 0, bass: 0, mids: 1, rms: 0, beat: false), name: "grid")
        let rows = Int(0.62 * Double(Self.height))..<Int(0.75 * Double(Self.height))
        // A single horizontal grid line is legitimately a full-width bright row or two; a slab
        // is a run of them.
        var longestRun = 0, run = 0
        for y in rows {
            let solid = (0..<Self.width).filter { image.rgb($0, y).y > 0.6 }.count > Self.width * 9 / 10
            run = solid ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        #expect(longestRun < 6, "\(longestRun) consecutive rows almost entirely bright cyan")
    }

    @Test func silencePadAndKickLookDistinct() throws {
        let silence = try render(Self.silence, name: "silence")
        let pad = try render(Self.pad, name: "pad")
        let kick = try render(Self.kick, name: "kick")
        #expect(silence.meanDifference(pad) > 0.01)
        #expect(silence.meanDifference(kick) > 0.01)
        #expect(pad.meanDifference(kick) > 0.01)
    }

    @Test func frameRendersWithinA120HzBudgetAtNativeResolution() throws {
        // 16-inch MacBook Pro native resolution; 120 Hz leaves 8.3 ms per frame.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(device: device, outputFormat: .bgra8Unorm)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 3456, height: 2234, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        let output = try #require(device.makeTexture(descriptor: desc))
        let queue = try #require(device.makeCommandQueue())
        var state = SceneState()
        var gpuSeconds: [Double] = []
        for frame in 0..<40 {
            state.advance(Self.kick, dt: 1.0 / 120)
            let buffer = try #require(queue.makeCommandBuffer())
            renderer.encode(into: buffer, output: output,
                            uniforms: state.uniforms(width: 3456, height: 2234), features: Self.kick)
            buffer.commit()
            buffer.waitUntilCompleted()
            if frame >= 10 { gpuSeconds.append(buffer.gpuEndTime - buffer.gpuStartTime) }
        }
        let average = gpuSeconds.reduce(0, +) / Double(gpuSeconds.count)
        #expect(average < 1.0 / 120, "average GPU time \(average * 1000) ms")
    }
}
