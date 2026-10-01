import Foundation
import Metal

/// Full-screen texture blit, replacing MetalSprocketsAddOns'
/// `TextureBillboardPipeline`. Draws `source` into `target` with a built-in
/// full-screen-triangle shader (see `Resources/Billboard.metal`). Metal 4.
final class BillboardPipeline {
    private let device: MTLDevice
    private let compiler: MTL4Compiler
    private let library: MTLLibrary

    /// Render pipeline states cached per color-attachment pixel format, since
    /// the target texture's format isn't known until encode time.
    private var pipelineStates: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    /// Fresh per-encode uniforms buffers, held until the next encode so the GPU
    /// finishes reading them.
    private var uniformsBuffers: [MTLBuffer] = []

    /// Matches `BillboardUniforms` in Billboard.metal.
    private struct Uniforms {
        var flipY: UInt32
    }

    init(device: MTLDevice, compiler: MTL4Compiler) throws {
        self.device = device
        self.compiler = compiler
        self.library = try device.makeDefaultLibrary(bundle: .module)
        guard library.makeFunction(name: "phosphor_billboard_vertex") != nil,
              library.makeFunction(name: "phosphor_billboard_fragment") != nil else {
            throw BillboardError.missingFunction
        }
    }

    private func functionDescriptor(_ name: String) -> MTL4LibraryFunctionDescriptor {
        let descriptor = MTL4LibraryFunctionDescriptor()
        descriptor.library = library
        descriptor.name = name
        return descriptor
    }

    private func pipelineState(for pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = pipelineStates[pixelFormat] { return cached }
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "Phosphor.Billboard"
        descriptor.vertexFunctionDescriptor = functionDescriptor("phosphor_billboard_vertex")
        descriptor.fragmentFunctionDescriptor = functionDescriptor("phosphor_billboard_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let state = try compiler.makeRenderPipelineState(descriptor: descriptor)
        pipelineStates[pixelFormat] = state
        return state
    }

    /// Allocations this pipeline needs resident for the current frame.
    func residentAllocations() -> [MTLAllocation] {
        uniformsBuffers
    }

    /// Call once per frame, before encoding, to release the previous frame's
    /// uniforms buffers.
    func beginFrame() {
        uniformsBuffers.removeAll(keepingCapacity: true)
    }

    /// Encodes the blit into `encoder`. The caller opens the render encoder with
    /// a pass that targets `target`; this binds the pipeline, the source texture
    /// and the flip flag, then draws the full-screen triangle.
    func encode(into encoder: MTL4RenderCommandEncoder, source: MTLTexture, targetPixelFormat: MTLPixelFormat, flipY: Bool) {
        guard let pipelineState = try? pipelineState(for: targetPixelFormat),
              let uniformsBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared) else {
            return
        }
        uniformsBuffer.label = "Phosphor.Billboard.Uniforms"
        uniformsBuffer.contents().storeBytes(of: Uniforms(flipY: flipY ? 1 : 0), as: Uniforms.self)
        uniformsBuffers.append(uniformsBuffer)

        encoder.label = "Phosphor.Billboard"
        encoder.setRenderPipelineState(pipelineState)

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        tableDescriptor.maxTextureBindCount = 1
        tableDescriptor.initializeBindings = true
        guard let table = try? device.makeArgumentTable(descriptor: tableDescriptor) else { return }
        table.setAddress(uniformsBuffer.gpuAddress, index: 0)
        table.setTexture(source.gpuResourceID, index: 0)
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])

        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    }

    enum BillboardError: Error {
        case missingFunction
    }
}
