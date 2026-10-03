import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
@testable import PhosphorRuntime
import Testing

/// #5: steady-state frames reuse a fixed pool of residency sets instead of
/// creating one per frame.
@Suite("Residency set reuse", .enabled(if: metal4Available))
struct ResidencyReuseTests {
    @Test("Residency sets created stay bounded across many frames")
    @MainActor
    func boundedCreation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = RenderSmokeTests.examplesDirectory.appendingPathComponent("Checkerboard.metal")
        let parsed = ParsedPhosphorSource(source: try String(contentsOf: url, encoding: .utf8))
        let runtime = PhosphorRuntime(configuration: parsed.configuration, source: parsed.body)
        let renderer = try PhosphorRenderer(device: device, maxFramesInFlight: 3)
        let harness = try Metal4Harness(device: device)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))

        for frame in 0..<20 {
            try harness.run { commandBuffer in
                try renderer.render(
                    runtime: runtime,
                    into: commandBuffer,
                    targetTexture: target,
                    drawableSize: CGSize(width: 32, height: 32),
                    builtin: BuiltinUniforms(time: 0, timeDelta: 0, frame: Float(frame), resolution: SIMD2(32, 32))
                )
            }
        }
        // One stable set plus a dynamic pool of maxFramesInFlight + 1.
        #expect(renderer.residencySetsCreated <= 1 + 4)
    }
}
