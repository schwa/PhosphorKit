import Foundation
import Metal

/// Full-screen texture blit, replacing MetalSprocketsAddOns'
/// `TextureBillboardPipeline`. Draws `source` into `target` with a built-in
/// full-screen-triangle shader (see `Resources/Billboard.metal`).
final class BillboardPipeline {
    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let fragmentFunction: MTLFunction

    /// Render pipeline states cached per color-attachment pixel format, since
    /// the target texture's format isn't known until encode time (drawable vs.
    /// MetalSprockets render target may differ).
    private var pipelineStates: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    /// Matches `BillboardUniforms` in Billboard.metal.
    private struct Uniforms {
        var flipY: UInt32
    }

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeDefaultLibrary(bundle: .module)
        guard let vertexFunction = library.makeFunction(name: "phosphor_billboard_vertex"),
              let fragmentFunction = library.makeFunction(name: "phosphor_billboard_fragment") else {
            throw BillboardError.missingFunction
        }
        self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction
    }

    private func pipelineState(for pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = pipelineStates[pixelFormat] { return cached }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Phosphor.Billboard"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelineStates[pixelFormat] = state
        return state
    }

    /// Encodes the blit into `commandBuffer`. The render pass clears the target
    /// to transparent before drawing the full-screen triangle.
    func encode(into commandBuffer: MTLCommandBuffer, source: MTLTexture, target: MTLTexture, flipY: Bool) {
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let pipelineState = try? pipelineState(for: target.pixelFormat),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        encoder.label = "Phosphor.Billboard"
        encoder.setRenderPipelineState(pipelineState)

        var uniforms = Uniforms(flipY: flipY ? 1 : 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    enum BillboardError: Error {
        case missingFunction
    }
}
