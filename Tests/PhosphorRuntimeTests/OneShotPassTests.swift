import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
@testable import PhosphorRuntime
import Testing

/// Covers the scheduling flag behind `Pass.once` (#104): one-shot passes run
/// on the first frame after their state is invalidated, and are skipped
/// otherwise.
@Suite("One-shot passes", .enabled(if: metalDeviceAvailable))
struct OneShotPassTests {
    @Test("Pending on a fresh runtime, then consumed")
    @MainActor
    func pendingAtInit() {
        let runtime = PhosphorRuntime()
        #expect(runtime.consumeOneShotPasses())
        #expect(!runtime.consumeOneShotPasses())
    }

    @Test("A reset re-arms them")
    @MainActor
    func resetRearms() {
        let runtime = PhosphorRuntime()
        _ = runtime.consumeOneShotPasses()
        runtime.signalReset()
        #expect(runtime.consumeOneShotPasses())
        #expect(!runtime.consumeOneShotPasses())
    }

    @Test("A reload re-arms them")
    @MainActor
    func reloadRearms() {
        let runtime = PhosphorRuntime()
        _ = runtime.consumeOneShotPasses()
        runtime.update(parsed: ParsedPhosphorSource(source: "kernel void image() {}\n"))
        #expect(runtime.consumeOneShotPasses())
    }

    /// A reallocated texture is blank, so whatever a one-shot pass wrote into
    /// it is gone and it has to run again.
    @Test("Allocating a texture re-arms them")
    @MainActor
    func allocationRearms() throws {
        let runtime = PhosphorRuntime()
        let source = """
        /* phosphor:environment
        output = "image"
        [[textures]]
        id = "image"
        size = "drawable"
        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        */
        kernel void image() {}
        """
        runtime.update(parsed: ParsedPhosphorSource(source: source))
        _ = runtime.consumeOneShotPasses()

        try runtime.ensureTextures(drawableSize: CGSize(width: 64, height: 64))
        #expect(runtime.consumeOneShotPasses(), "first allocation should re-arm")

        try runtime.ensureTextures(drawableSize: CGSize(width: 64, height: 64))
        #expect(!runtime.consumeOneShotPasses(), "an unchanged size allocates nothing")

        try runtime.ensureTextures(drawableSize: CGSize(width: 128, height: 128))
        #expect(runtime.consumeOneShotPasses(), "a resize reallocates and re-arms")
    }
}

/// End-to-end check that the renderer actually skips one-shot passes.
///
/// The `seed` pass writes the current time into a 1×1 store; `image` copies
/// the store to the output. If `once` were ignored, the store would track time
/// on every frame instead of holding the first frame's value.
@Suite("One-shot passes end to end", .enabled(if: metal4Available))
struct OneShotPassRenderTests {
    static func source(once: Bool) -> String {
        """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "store"
        size = { fixed = { width = 1, height = 1 } }
        format = "rgba32Float"

        [[textures]]
        id = "image"
        size = "drawable"
        format = "rgba32Float"

        [[passes]]
        id = "seed"
        once = \(once)
        textures = [{ id = "store", access = "write" }]

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }, { id = "store", access = "read" }]
        */

        uint2 gid [[thread_position_in_grid]];

        kernel void seed(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            uniforms.textures.store.write(float4(uniforms.time, 0, 0, 1), uint2(0, 0));
        }

        kernel void image(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            uniforms.textures.image.write(uniforms.textures.store.read(uint2(0, 0)), gid);
        }
        """
    }

    /// Renders frames at t = 0, 1, 2 and returns the red channel of the output
    /// after the last one.
    @MainActor
    static func redAfterThreeFrames(once: Bool) throws -> Float {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let parsed = ParsedPhosphorSource(source: source(once: once))
        #expect(parsed.diagnostics.isEmpty, "validation: \(parsed.diagnostics)")

        let runtime = PhosphorRuntime(configuration: parsed.configuration, source: parsed.body)
        #expect(runtime.diagnostics.isEmpty, "compile: \(runtime.diagnostics)")

        let size = CGSize(width: 1, height: 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))

        let renderer = try PhosphorRenderer(device: device)
        let harness = try Metal4Harness(device: device)
        for frame in 0..<3 {
            try harness.run { commandBuffer in
                try renderer.render(
                    runtime: runtime,
                    into: commandBuffer,
                    targetTexture: target,
                    drawableSize: size,
                    builtin: BuiltinUniforms(
                        time: Float(frame),
                        timeDelta: 1,
                        frame: Float(frame),
                        resolution: SIMD2<Float>(1, 1)
                    )
                )
            }
        }

        var pixel = SIMD4<Float>(repeating: 0)
        withUnsafeMutableBytes(of: &pixel) { buffer in
            target.getBytes(
                buffer.baseAddress!,
                bytesPerRow: MemoryLayout<SIMD4<Float>>.size,
                from: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0
            )
        }
        return pixel.x
    }

    @Test("A once pass keeps the value it wrote on the first frame")
    @MainActor
    func onceHoldsFirstFrameValue() throws {
        #expect(try Self.redAfterThreeFrames(once: true) == 0)
    }

    /// The control: the same shader without `once` tracks time every frame, so
    /// the test above is measuring the skip and not something incidental.
    @Test("Without once, the same pass tracks time every frame")
    @MainActor
    func perFramePassTracksTime() throws {
        #expect(try Self.redAfterThreeFrames(once: false) == 2)
    }
}

@Suite("Pass.once coding")
struct PassOnceCodingTests {
    @Test("Defaults to false when absent")
    func defaultsToFalse() throws {
        let json = #"{"id": "image"}"#
        let pass = try JSONDecoder().decode(Pass.self, from: Data(json.utf8))
        #expect(!pass.once)
    }

    @Test("Round-trips when set")
    func roundTrips() throws {
        let pass = Pass(id: "seed", once: true)
        let data = try JSONEncoder().encode(pass)
        #expect(try JSONDecoder().decode(Pass.self, from: data).once)
    }

    /// Kept out of the encoded form when false so round-tripped front-matter
    /// doesn't grow a `once = false` line on every pass.
    @Test("Omitted from the encoded form when false")
    func omittedWhenFalse() throws {
        let data = try JSONEncoder().encode(Pass(id: "image"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("once"))
    }
}
