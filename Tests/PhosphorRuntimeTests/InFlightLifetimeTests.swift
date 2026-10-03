import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
@testable import PhosphorRuntime
import Testing

/// #2: MTL4 command buffers don't retain resources, so the renderer must keep
/// per-frame buffers alive while later frames are encoded.
@Suite("In-flight resource lifetime", .enabled(if: metal4Available))
struct InFlightLifetimeTests {
    @Test("Previous frame's per-frame buffers outlive the next frame's encode")
    @MainActor
    func perFrameBuffersRetained() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = RenderSmokeTests.examplesDirectory.appendingPathComponent("Checkerboard.metal")
        let parsed = ParsedPhosphorSource(source: try String(contentsOf: url, encoding: .utf8))
        let runtime = PhosphorRuntime(configuration: parsed.configuration, source: parsed.body)
        let renderer = try PhosphorRenderer(device: device)

        let size = CGSize(width: 64, height: 64)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))
        let allocator = try device.makeCommandAllocator(descriptor: MTL4CommandAllocatorDescriptor())

        weak var userUniforms: MTLBuffer?
        weak var passUniforms: MTLBuffer?
        // Encode frames without committing: each stands in for an in-flight frame.
        var commandBuffers: [MTL4CommandBuffer] = []
        for frame in 0..<2 {
            try autoreleasepool {
                let commandBuffer = try #require(device.makeCommandBuffer())
                commandBuffer.beginCommandBuffer(allocator: allocator)
                try renderer.render(
                    runtime: runtime,
                    into: commandBuffer,
                    targetTexture: target,
                    drawableSize: size,
                    builtin: BuiltinUniforms(time: 0, timeDelta: 0, frame: Float(frame), resolution: SIMD2(64, 64))
                )
                commandBuffer.endCommandBuffer()
                commandBuffers.append(commandBuffer)
                if frame == 0 {
                    userUniforms = runtime.userUniformsBuffer
                    passUniforms = parsed.configuration.passes.first.flatMap { runtime.passUniformsBuffer(for: $0.id) }
                }
            }
        }
        #expect(userUniforms != nil)
        #expect(passUniforms != nil)
    }
}
