import Foundation
import Metal
import PhosphorCompile
import PhosphorModel

/// Metal 4 render driver for a ``PhosphorRuntime``.
///
/// Replaces the previous raw-Metal-3 driver: it owns the compute pipeline-state
/// cache and the per-frame encode loop, and is *view-agnostic* — the caller
/// supplies an `MTL4CommandBuffer` (already begun) and a target texture. The
/// renderer keeps a persistent residency set for long-lived resources and a
/// small per-frame set for the drawable and fresh per-frame uniform buffers,
/// so the caller does not manage residency.
///
/// Metal 4 has no automatic hazard tracking: the renderer orders dependent
/// compute passes with intra-encoder barriers, and orders the final billboard
/// draw after all compute work with a producer barrier.
///
/// Ping-pong parity is derived from the frame counter — even frames use parity
/// A, odd frames parity B. No cross-frame state lives here beyond the pipeline
/// caches.
public final class PhosphorRenderer {
    private let device: MTLDevice
    private let compiler: MTL4Compiler

    private var computePipelineStates: [ResourceID: MTLComputePipelineState] = [:]
    private var cachedLibrary: MTLLibrary?

    private lazy var billboard: BillboardPipeline? = try? BillboardPipeline(device: device, compiler: compiler)

    /// Keeps recent per-frame (dynamic) residency sets and retired stable sets
    /// alive until their GPU work retires.
    private var residencyRing: [MTLResidencySet] = []
    private static let residencyRingDepth = 4

    /// Persistent residency set for long-lived resources (uniform/audio
    /// buffers, fallback texture, ping-pong textures). Rebuilt only when its
    /// membership changes (resize or recompile), not every frame, to avoid the
    /// per-frame addAllocation/removeAllocation churn Metal 4's automatic
    /// submission-scoped residency would otherwise cause.
    private var stableResidencySet: MTLResidencySet?
    private var zeroBuffer: MTLBuffer?
    private var stableResidencySignature: Set<ObjectIdentifier> = []

    public init(device: MTLDevice) throws {
        self.device = device
        self.compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    }

    /// Drops cached compute pipeline states. Call after the runtime recompiles.
    public func invalidatePipelineStates() {
        computePipelineStates.removeAll()
        cachedLibrary = nil
    }

    /// Encodes one full frame into `commandBuffer`: every enabled compute pass,
    /// then a billboard blit of the output texture into `targetTexture`.
    ///
    /// The caller must have already called `beginCommandBuffer(allocator:)` and
    /// is responsible for `endCommandBuffer()`, committing, and presenting.
    public func render(
        runtime: PhosphorRuntime,
        into commandBuffer: MTL4CommandBuffer,
        targetTexture: MTLTexture,
        drawableSize: CGSize,
        builtin: BuiltinUniforms,
        userUniformValues: [String: UniformValue] = [:],
        displayedResource: ResourceID? = nil
    ) throws {
        try? runtime.ensureTextures(drawableSize: drawableSize)
        runtime.writeAudioBuffers()
        runtime.writeUserUniforms(userUniformValues)
        billboard?.beginFrame()

        if cachedLibrary !== runtime.library {
            computePipelineStates.removeAll()
            cachedLibrary = runtime.library
        }

        let isEvenFrame = (UInt64(builtin.frame) % 2) == 0
        var parityByResource: [ResourceID: Bool] = [:]
        for texture in runtime.configuration.textures {
            parityByResource[texture.id] = (texture.swap != .none) ? isEvenFrame : true
        }
        _ = runtime.writePassUniforms(builtin: builtin, parity: parityByResource)
        let runOneShotPasses = runtime.consumeOneShotPasses()

        // Residency: everything a dispatch or draw reaches, directly or through
        // the Uniforms argument buffer. Metal 4 does not infer this. Split into
        // stable resources (same objects every frame -> persistent set) and
        // dynamic ones (drawable + fresh per-frame uniform buffers).
        var stableAllocations: [MTLAllocation] = [runtime.fallbackTexture]
        for (_, pair) in runtime.textures {
            stableAllocations.append(pair.a)
            if pair.pingPong { stableAllocations.append(pair.b) }
        }
        // Per-frame resources: the drawable (a fresh texture most frames, the
        // layer does not recycle a small pool here) plus the user-uniforms and
        // audio buffers (reallocated every frame to dodge in-flight write races).
        var dynamicAllocations: [MTLAllocation] = [
            targetTexture,
            runtime.userUniformsBuffer,
            runtime.waveformBuffer,
            runtime.spectrumBuffer
        ]

        let encodedPasses = runtime.configuration.passes.filter { $0.enabled && (!$0.once || runOneShotPasses) }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            // MTL4 doesn't serialize command buffers. Wait for the previous
            // frame's compute and billboard work before touching the shared
            // ping-pong textures.
            encoder.barrier(afterQueueStages: [.dispatch, .vertex, .fragment], beforeStages: .dispatch, visibilityOptions: .device)
            let clears = runtime.consumePendingClears()
            if !clears.isEmpty, let zero = encodeClears(clears, encoder: encoder) {
                dynamicAllocations.append(zero)
                encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
            }
            for (passIndex, pass) in encodedPasses.enumerated() {
                if let passBuffer = runtime.passUniformsBuffer(for: pass.id) {
                    dynamicAllocations.append(passBuffer)
                }
                try encodeComputePass(
                    pass,
                    runtime: runtime,
                    encoder: encoder,
                    parity: parityByResource
                )
                // Order the next pass after this one; a later pass may read a
                // texture this pass wrote.
                if passIndex < encodedPasses.count - 1 {
                    encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
                }
            }
            // Order the billboard draw after all compute work.
            encoder.barrier(afterStages: .dispatch, beforeQueueStages: [.vertex, .fragment], visibilityOptions: .device)
            encoder.endEncoding()
        }

        // Billboard the chosen output's write target into the target texture.
        let outputResourceID: ResourceID = {
            if let chosen = displayedResource, runtime.textures[chosen] != nil {
                return chosen
            }
            return runtime.configuration.output
        }()
        if let outputTexture = runtime.textures[outputResourceID]?.writeTexture(currentIsA: parityByResource[outputResourceID] ?? true),
           let billboard {
            dynamicAllocations.append(contentsOf: billboard.residentAllocations())
            applyResidency(stable: stableAllocations, dynamic: dynamicAllocations, to: commandBuffer)

            let renderPass = MTL4RenderPassDescriptor()
            renderPass.colorAttachments[0].texture = targetTexture
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].storeAction = .store
            renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
                billboard.encode(into: encoder, source: outputTexture, targetPixelFormat: targetTexture.pixelFormat, flipY: runtime.configuration.flipY)
                encoder.endEncoding()
            }
        } else {
            applyResidency(stable: stableAllocations, dynamic: dynamicAllocations, to: commandBuffer)
        }
    }

    /// Copies zeros into each texture. Returns the zero buffer, which must be
    /// resident for this frame.
    private func encodeClears(_ textures: [MTLTexture], encoder: MTL4ComputeCommandEncoder) -> MTLBuffer? {
        // Every texture here was allocated from a PhosphorPixelFormat; the
        // fallback is the widest format, which over-sizes rather than under-fills.
        func layout(_ texture: MTLTexture) -> (bytesPerRow: Int, length: Int) {
            let bytesPerRow = texture.width * (PhosphorPixelFormat(texture.pixelFormat)?.bytesPerPixel ?? 16)
            return (bytesPerRow, bytesPerRow * texture.height)
        }
        let needed = textures.map { layout($0).length }.max() ?? 0
        if (zeroBuffer?.length ?? 0) < needed {
            zeroBuffer = device.makeBuffer(length: needed, options: .storageModeShared)
            zeroBuffer?.label = "Phosphor.Zero"
            if let zeroBuffer { memset(zeroBuffer.contents(), 0, zeroBuffer.length) }
        }
        guard let zeroBuffer else { return nil }
        for texture in textures {
            let (bytesPerRow, length) = layout(texture)
            encoder.copy(
                sourceBuffer: zeroBuffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                sourceBytesPerImage: length,
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                destinationTexture: texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        return zeroBuffer
    }

    private func applyResidency(stable: [MTLAllocation], dynamic: [MTLAllocation], to commandBuffer: MTL4CommandBuffer) {
        if let stableSet = stableResidencySet(for: stable) {
            commandBuffer.useResidencySet(stableSet)
        }
        if let dynamicSet = makeResidencySet(dynamic, label: "Phosphor.Residency.Dynamic") {
            commandBuffer.useResidencySet(dynamicSet)
            residencyRing.append(dynamicSet)
            if residencyRing.count > Self.residencyRingDepth {
                residencyRing.removeFirst(residencyRing.count - Self.residencyRingDepth)
            }
        }
    }

    /// Returns the persistent residency set for `allocations`, rebuilding it
    /// only when the membership changed since the last frame. A retired set is
    /// kept alive via `residencyRing` until in-flight work that used it retires.
    private func stableResidencySet(for allocations: [MTLAllocation]) -> MTLResidencySet? {
        let signature = Set(allocations.map { ObjectIdentifier($0 as AnyObject) })
        if let set = stableResidencySet, signature == stableResidencySignature {
            return set
        }
        guard let set = makeResidencySet(allocations, label: "Phosphor.Residency.Stable") else {
            return nil
        }
        if let old = stableResidencySet {
            residencyRing.append(old)
            if residencyRing.count > Self.residencyRingDepth {
                residencyRing.removeFirst(residencyRing.count - Self.residencyRingDepth)
            }
        }
        stableResidencySet = set
        stableResidencySignature = signature
        return set
    }

    private func makeResidencySet(_ allocations: [MTLAllocation], label: String) -> MTLResidencySet? {
        guard !allocations.isEmpty else { return nil }
        let descriptor = MTLResidencySetDescriptor()
        descriptor.label = label
        guard let set = try? device.makeResidencySet(descriptor: descriptor) else {
            return nil
        }
        for allocation in allocations {
            set.addAllocation(allocation)
        }
        set.commit()
        return set
    }

    private func primaryWriteTexture(for pass: Pass, runtime: PhosphorRuntime, parity: [ResourceID: Bool]) -> MTLTexture? {
        guard let binding = pass.textures.first(where: { $0.access == .write || $0.access == .readWrite }) else {
            return nil
        }
        let resourceParity = parity[binding.id] ?? true
        return runtime.textures[binding.id]?.writeTexture(currentIsA: resourceParity)
    }

    private func computePipelineState(for pass: Pass, name: String) throws -> MTLComputePipelineState {
        if let cached = computePipelineStates[pass.id] { return cached }
        guard let library = cachedLibrary else {
            throw PhosphorRuntimeError.allocationFailed("compute pipeline \(pass.id.raw): no library")
        }
        let functionDescriptor = MTL4LibraryFunctionDescriptor()
        functionDescriptor.library = library
        functionDescriptor.name = name
        let descriptor = MTL4ComputePipelineDescriptor()
        descriptor.label = pass.id.raw
        descriptor.computeFunctionDescriptor = functionDescriptor
        let state = try compiler.makeComputePipelineState(descriptor: descriptor)
        computePipelineStates[pass.id] = state
        return state
    }

    private func encodeComputePass(
        _ pass: Pass,
        runtime: PhosphorRuntime,
        encoder: MTL4ComputeCommandEncoder,
        parity: [ResourceID: Bool]
    ) throws {
        guard let function = runtime.passFunctions[pass.id],
              let dispatchTarget = primaryWriteTexture(for: pass, runtime: runtime, parity: parity),
              let passBuffer = runtime.passUniformsBuffer(for: pass.id) else {
            return
        }

        let state = try computePipelineState(for: pass, name: function.name)
        encoder.setComputePipelineState(state)

        // Generated kernels bind `uniforms` at buffer(0) and `userUniforms` at
        // buffer(1) by convention (see StarterTemplate.metal / Phosphor.h).
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 2
        tableDescriptor.initializeBindings = true
        let table = try device.makeArgumentTable(descriptor: tableDescriptor)
        table.setAddress(passBuffer.gpuAddress, index: 0)
        table.setAddress(runtime.userUniformsBuffer.gpuAddress, index: 1)
        encoder.setArgumentTable(table)

        let threadsPerGrid = MTLSize(width: dispatchTarget.width, height: dispatchTarget.height, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid: threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
