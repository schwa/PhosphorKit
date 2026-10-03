import Foundation
import Metal
import PhosphorModel
@testable import PhosphorRuntime
import Testing

/// Covers the widened pixel-format set (#68).
///
/// Phosphor allocates every texture `[.shaderRead, .shaderWrite]` and kernels
/// bind them as `texture2d<float, …>`, so a format is only offerable if a
/// compute shader can genuinely write it and read the value back. These tests
/// check that on the real device rather than trusting the format tables.
@Suite("Pixel formats")
struct PixelFormatTests {
    @Test("Every declared format maps to a distinct Metal format")
    func mappingIsInjective() {
        let metal = PhosphorPixelFormat.allCases.map(\.metalPixelFormat)
        #expect(Set(metal).count == PhosphorPixelFormat.allCases.count)
    }

    @Test("The Metal mapping round-trips", arguments: PhosphorPixelFormat.allCases)
    func roundTrips(format: PhosphorPixelFormat) {
        #expect(PhosphorPixelFormat(format.metalPixelFormat) == format)
    }

    @Test("A Metal format Phosphor can't declare returns nil")
    func rejectsUnknown() {
        #expect(PhosphorPixelFormat(.depth32Float) == nil)
        #expect(PhosphorPixelFormat(.invalid) == nil)
    }

    /// `bytesPerPixel` sizes the zero-fill buffer when a texture is cleared,
    /// so an understated value would leave part of it holding stale pixels.
    ///
    /// Checked against Metal by pushing a byte pattern through
    /// `replace`/`getBytes` at our computed stride: if the stride were wrong,
    /// the rows would shear and the bytes wouldn't come back unchanged.
    @Test("bytesPerPixel matches Metal's row stride", .enabled(if: metalDeviceAvailable), arguments: PhosphorPixelFormat.allCases)
    @MainActor
    func bytesPerPixelMatchesMetal(format: PhosphorPixelFormat) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let width = 4
        let height = 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format.metalPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        let bytesPerRow = width * format.bytesPerPixel
        // A pattern that differs per byte, so any shear or truncation shows up.
        let written = (0..<(bytesPerRow * height)).map { UInt8($0 % 251) }
        let region = MTLRegionMake2D(0, 0, width, height)
        written.withUnsafeBytes { buffer in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }

        var readBack = [UInt8](repeating: 0, count: written.count)
        readBack.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }
        #expect(readBack == written, "\(format) didn't round-trip at \(format.bytesPerPixel) bytes/pixel")
    }

    /// The real bar: allocate the format the way Phosphor does, have a compute
    /// kernel write to it, and read the value back.
    @Test("Every declared format is writable and readable from a kernel", .enabled(if: metal4Available), arguments: PhosphorPixelFormat.allCases)
    @MainActor
    func formatSurvivesAKernelRoundTrip(format: PhosphorPixelFormat) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void fill(texture2d<float, access::write> w [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
            w.write(float4(1.0, 0.0, 0.0, 1.0), gid);
        }
        kernel void readBack(texture2d<float, access::read> r [[texture(0)]],
                             device float4* out [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
            out[0] = r.read(gid);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            let functionDescriptor = MTL4LibraryFunctionDescriptor()
            functionDescriptor.library = library
            functionDescriptor.name = name
            let descriptor = MTL4ComputePipelineDescriptor()
            descriptor.computeFunctionDescriptor = functionDescriptor
            return try compiler.makeComputePipelineState(descriptor: descriptor)
        }
        let fill = try pipeline("fill")
        let readBack = try pipeline("readBack")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format.metalPixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let output = try #require(device.makeBuffer(length: 16, options: .storageModeShared))

        let one = MTLSize(width: 1, height: 1, depth: 1)

        func textureTable() throws -> MTL4ArgumentTable {
            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.maxTextureBindCount = 1
            descriptor.initializeBindings = true
            let table = try device.makeArgumentTable(descriptor: descriptor)
            table.setTexture(texture.gpuResourceID, index: 0)
            return table
        }
        func readTable() throws -> MTL4ArgumentTable {
            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.maxTextureBindCount = 1
            descriptor.maxBufferBindCount = 1
            descriptor.initializeBindings = true
            let table = try device.makeArgumentTable(descriptor: descriptor)
            table.setTexture(texture.gpuResourceID, index: 0)
            table.setAddress(output.gpuAddress, index: 0)
            return table
        }
        let fillTable = try textureTable()
        let readTableInstance = try readTable()

        let harness = try Metal4Harness(device: device)
        try harness.run(resident: [texture, output]) { commandBuffer in
            if let fillEncoder = commandBuffer.makeComputeCommandEncoder() {
                fillEncoder.setComputePipelineState(fill)
                fillEncoder.setArgumentTable(fillTable)
                fillEncoder.dispatchThreads(threadsPerGrid: one, threadsPerThreadgroup: one)
                fillEncoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
                fillEncoder.setComputePipelineState(readBack)
                fillEncoder.setArgumentTable(readTableInstance)
                fillEncoder.dispatchThreads(threadsPerGrid: one, threadsPerThreadgroup: one)
                fillEncoder.endEncoding()
            }
        }

        let pixel = output.contents().bindMemory(to: Float.self, capacity: 4)
        // Loose tolerance: the packed and 8-bit formats quantise.
        #expect(abs(pixel[0] - 1.0) < 0.02, "\(format) red came back \(pixel[0])")
        #expect(abs(pixel[1]) < 0.02, "\(format) green came back \(pixel[1])")
    }
}
