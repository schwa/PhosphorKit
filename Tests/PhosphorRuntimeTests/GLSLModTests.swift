import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
@testable import PhosphorRuntime
import Testing

/// MSL has no `mod()`, so Phosphor.h supplies one (#142). It has to follow
/// GLSL's definition rather than being an alias for `fmod()`: the two agree
/// for non-negative arguments and disagree for negative ones, so the
/// interesting cases are all below zero.
@Suite("GLSL mod()")
struct GLSLModTests {
    /// Runs a one-pixel shader whose body must assign `float4 result`, and
    /// returns the value it wrote.
    @MainActor
    static func evaluate(_ body: String) throws -> SIMD4<Float> {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSkip.noDevice }
        let source = """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "image"
        size = { fixed = { width = 1, height = 1 } }
        format = "rgba32Float"

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        */

        uint2 gid [[thread_position_in_grid]];

        kernel void image(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            \(body)
            uniforms.textures.image.write(result, gid);
        }
        """
        let parsed = ParsedPhosphorSource(source: source)
        #expect(parsed.diagnostics.isEmpty, "validation: \(parsed.diagnostics)")
        let runtime = PhosphorRuntime(configuration: parsed.configuration, source: parsed.body)
        #expect(runtime.diagnostics.isEmpty, "compile: \(runtime.diagnostics)")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))

        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try PhosphorRenderer(device: device).render(
            runtime: runtime,
            into: commandBuffer,
            targetTexture: target,
            drawableSize: CGSize(width: 1, height: 1),
            builtin: BuiltinUniforms(resolution: SIMD2<Float>(1, 1))
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.error == nil, "\(String(describing: commandBuffer.error))")

        var pixel = SIMD4<Float>(repeating: 0)
        withUnsafeMutableBytes(of: &pixel) { buffer in
            target.getBytes(
                buffer.baseAddress!,
                bytesPerRow: MemoryLayout<SIMD4<Float>>.size,
                from: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0
            )
        }
        return pixel
    }

    /// GLSL: `mod(-1.5, 1.0) == 0.5`. Metal's `fmod` gives `-0.5`.
    @Test("mod() of a negative dividend takes the divisor's sign")
    @MainActor
    func negativeDividend() throws {
        let result = try Self.evaluate("float4 result = float4(mod(-1.5f, 1.0f), fmod(-1.5f, 1.0f), 0.0f, 1.0f);")
        #expect(abs(result.x - 0.5) < 1e-5, "mod gave \(result.x), expected 0.5")
        // The control: if this ever equals mod's result, the two have been
        // conflated again.
        #expect(abs(result.y - -0.5) < 1e-5, "fmod gave \(result.y), expected -0.5")
    }

    @Test("mod() matches fmod() for non-negative arguments")
    @MainActor
    func nonNegativeAgrees() throws {
        let result = try Self.evaluate("float4 result = float4(mod(5.5f, 2.0f), fmod(5.5f, 2.0f), 0.0f, 1.0f);")
        #expect(abs(result.x - 1.5) < 1e-5)
        #expect(abs(result.y - 1.5) < 1e-5)
    }

    @Test("Vector overloads work, including a scalar divisor")
    @MainActor
    func vectorOverloads() throws {
        let result = try Self.evaluate("""
            float2 a = mod(float2(-1.5f, 2.5f), float2(1.0f, 1.0f));
            float2 b = mod(float2(-0.25f, 3.75f), 1.0f);
            float4 result = float4(a, b);
            """)
        #expect(abs(result.x - 0.5) < 1e-5)
        #expect(abs(result.y - 0.5) < 1e-5)
        #expect(abs(result.z - 0.75) < 1e-5)
        #expect(abs(result.w - 0.75) < 1e-5)
    }
}
