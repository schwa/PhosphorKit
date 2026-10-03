import Metal
@testable import PhosphorRuntime
import Testing

/// #1: the uniforms buffer the billboard draw reads must be in the residency
/// set, which the renderer builds between `beginFrame()` and `encode`.
@Suite("Billboard residency")
struct BillboardResidencyTests {
    @Test("Uniforms buffer is resident before encode")
    func uniformsResidentBeforeEncode() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSkip.noDevice }
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let billboard = try BillboardPipeline(device: device, compiler: compiler)

        billboard.beginFrame()
        let resident = billboard.residentAllocations()
        #expect(!resident.isEmpty)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        textureDescriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        let harness = try Metal4Harness(device: device)
        try harness.run(resident: resident + [texture]) { commandBuffer in
            let pass = MTL4RenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
            billboard.encode(into: encoder, source: texture, targetPixelFormat: texture.pixelFormat, flipY: false)
            encoder.endEncoding()
        }

        // Encode must use the resident buffer, not allocate a new one.
        let after = billboard.residentAllocations()
        #expect(after.count == resident.count)
        #expect(zip(after, resident).allSatisfy { $0 === $1 })
    }
}
