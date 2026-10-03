import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
@testable import PhosphorRuntime
import Testing

/// `signalReset()` must leave ping-pong textures zeroed by the next frame (#6
/// moved the clear onto the frame's command buffer).
@Suite("Reset clears ping-pong textures")
struct ResetClearTests {
    @Test("Ping-pong textures read back zero after reset + one frame")
    @MainActor
    func resetZeroes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSkip.noDevice }
        let url = RenderSmokeTests.examplesDirectory.appendingPathComponent("Bloom.metal")
        let parsed = ParsedPhosphorSource(source: try String(contentsOf: url, encoding: .utf8))
        var configuration = parsed.configuration
        // No passes, so only the reset clear touches the textures.
        for index in configuration.passes.indices { configuration.passes[index].enabled = false }
        let runtime = PhosphorRuntime(configuration: configuration, source: parsed.body)
        let renderer = try PhosphorRenderer(device: device)
        let harness = try Metal4Harness(device: device)

        let size = CGSize(width: 32, height: 32)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))
        func renderFrame() throws {
            try harness.run { commandBuffer in
                try renderer.render(
                    runtime: runtime,
                    into: commandBuffer,
                    targetTexture: target,
                    drawableSize: size,
                    builtin: BuiltinUniforms(time: 0, timeDelta: 0, frame: 0, resolution: SIMD2(32, 32))
                )
            }
        }

        try renderFrame()
        let pair = try #require(runtime.textures.values.first(where: \.pingPong))
        let textures = [pair.a, pair.b]
        let bytesPerPixel = try #require(PhosphorPixelFormat(pair.a.pixelFormat)).bytesPerPixel
        let bytesPerRow = pair.a.width * bytesPerPixel
        let length = bytesPerRow * pair.a.height
        let region = MTLSize(width: pair.a.width, height: pair.a.height, depth: 1)

        // Fill with non-zero bytes.
        let fill = try #require(device.makeBuffer(length: length, options: .storageModeShared))
        memset(fill.contents(), 0xAB, length)
        try harness.run(resident: textures + [fill]) { commandBuffer in
            let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
            for texture in textures {
                encoder.copy(sourceBuffer: fill, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: length, sourceSize: region, destinationTexture: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            }
            encoder.endEncoding()
        }

        runtime.signalReset()
        try renderFrame()

        let readback = try #require(device.makeBuffer(length: length * 2, options: .storageModeShared))
        try harness.run(resident: textures + [readback]) { commandBuffer in
            let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
            for (index, texture) in textures.enumerated() {
                encoder.copy(sourceTexture: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: region, destinationBuffer: readback, destinationOffset: index * length, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
            }
            encoder.endEncoding()
        }
        let bytes = UnsafeRawBufferPointer(start: readback.contents(), count: length * 2)
        #expect(bytes.allSatisfy { $0 == 0 })
    }
}
