import Foundation
import Metal
import PhosphorCompile
import PhosphorModel

/// Raw-Metal render driver for a ``PhosphorRuntime``.
///
/// Replaces the previous MetalSprockets-based `PhosphorPipeline`: it owns the
/// compute pipeline-state cache and the per-frame encode loop, and is
/// *view-agnostic* — the caller supplies a command buffer and a target texture
/// (a drawable's texture, or any offscreen render target). PhosphorKit's
/// ``PhosphorView`` drives it from an `MTKView`; the Phosphor app drives the
/// same renderer from inside a MetalSprockets `RenderView`.
///
/// Ping-pong parity is derived from the frame counter — even frames use parity
/// A, odd frames parity B — matching the old pipeline exactly. No cross-frame
/// state lives here beyond the pipeline-state cache.
public final class PhosphorRenderer {
    private let device: MTLDevice

    /// Cached compute pipeline states keyed by pass id. Built lazily on first
    /// use; invalidated by ``invalidatePipelineStates()`` on reload.
    private var computePipelineStates: [ResourceID: MTLComputePipelineState] = [:]

    /// The library/functions the cache was built against. If the runtime's
    /// library identity changes (recompile), the cache is dropped.
    private var cachedLibrary: MTLLibrary?

    private lazy var billboard: BillboardPipeline? = try? BillboardPipeline(device: device)

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Drops cached compute pipeline states. Call after the runtime recompiles
    /// (its `passFunctions` / `library` change).
    public func invalidatePipelineStates() {
        computePipelineStates.removeAll()
        cachedLibrary = nil
    }

    /// Encodes one full frame: every enabled compute pass, then a billboard
    /// blit of the output texture into `targetTexture`.
    ///
    /// - Parameters:
    ///   - runtime: GPU state (textures, functions, per-pass uniforms buffers).
    ///   - commandBuffer: command buffer to encode into. The caller commits and
    ///     presents.
    ///   - targetTexture: final render target (the drawable's texture).
    ///   - drawableSize: pixel size of the target; drives texture allocation.
    ///   - builtin: builtin uniforms for this frame (`resized`/audio filled in
    ///     by the runtime).
    ///   - userUniformValues: user uniform overrides for this frame.
    ///   - displayedResource: resource id whose write target gets blitted;
    ///     defaults to `configuration.output`.
    public func render(
        runtime: PhosphorRuntime,
        into commandBuffer: MTLCommandBuffer,
        targetTexture: MTLTexture,
        drawableSize: CGSize,
        builtin: BuiltinUniforms,
        userUniformValues: [String: UniformValue] = [:],
        displayedResource: ResourceID? = nil
    ) throws {
        try? runtime.ensureTextures(drawableSize: drawableSize)
        runtime.writeAudioBuffers()
        runtime.writeUserUniforms(userUniformValues)

        // Drop the pipeline cache if the runtime recompiled under us.
        if cachedLibrary !== runtime.library {
            computePipelineStates.removeAll()
            cachedLibrary = runtime.library
        }

        // Parity for every ping-pong texture, derived from the frame count.
        // Non-ping-pong textures get an entry (always true) so lookups don't
        // special-case them.
        let isEvenFrame = (UInt64(builtin.frame) % 2) == 0
        var parityByResource: [ResourceID: Bool] = [:]
        for texture in runtime.configuration.textures {
            parityByResource[texture.id] = (texture.swap != .none) ? isEvenFrame : true
        }
        let useLists = runtime.writePassUniforms(builtin: builtin, parity: parityByResource)

        for pass in runtime.configuration.passes where pass.enabled {
            try encodeComputePass(
                pass,
                runtime: runtime,
                commandBuffer: commandBuffer,
                parity: parityByResource,
                useResources: useLists[pass.id] ?? []
            )
        }

        // Billboard the chosen output's write target into the drawable.
        let outputResourceID: ResourceID = {
            if let chosen = displayedResource, runtime.textures[chosen] != nil {
                return chosen
            }
            return runtime.configuration.output
        }()
        if let outputTexture = runtime.textures[outputResourceID]?.writeTexture(currentIsA: parityByResource[outputResourceID] ?? true),
           let billboard {
            billboard.encode(
                into: commandBuffer,
                source: outputTexture,
                target: targetTexture,
                flipY: runtime.configuration.flipY
            )
        }
    }

    /// Finds the texture a pass writes to (its first `.write`/`.readWrite`
    /// binding); the dispatch grid matches that texture's dimensions.
    private func primaryWriteTexture(for pass: Pass, runtime: PhosphorRuntime, parity: [ResourceID: Bool]) -> MTLTexture? {
        guard let binding = pass.textures.first(where: { $0.access == .write || $0.access == .readWrite }) else {
            return nil
        }
        let resourceParity = parity[binding.id] ?? true
        return runtime.textures[binding.id]?.writeTexture(currentIsA: resourceParity)
    }

    private func computePipelineState(for pass: Pass, function: MTLFunction) throws -> MTLComputePipelineState {
        if let cached = computePipelineStates[pass.id] { return cached }
        let state = try device.makeComputePipelineState(function: function)
        computePipelineStates[pass.id] = state
        return state
    }

    private func encodeComputePass(
        _ pass: Pass,
        runtime: PhosphorRuntime,
        commandBuffer: MTLCommandBuffer,
        parity: [ResourceID: Bool],
        useResources: [MTLTexture]
    ) throws {
        guard let function = runtime.passFunctions[pass.id],
              let dispatchTarget = primaryWriteTexture(for: pass, runtime: runtime, parity: parity),
              let passBuffer = runtime.passUniformsBuffer(for: pass.id) else {
            return
        }

        let state = try computePipelineState(for: pass, function: function)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = pass.id.raw
        encoder.setComputePipelineState(state)

        // Generated kernels bind `uniforms` at buffer(0) and `userUniforms` at
        // buffer(1) by convention (see StarterTemplate.metal / Phosphor.h).
        encoder.setBuffer(passBuffer, offset: 0, index: 0)
        encoder.setBuffer(runtime.userUniformsBuffer, offset: 0, index: 1)

        // Residency: the Uniforms argument buffer references these textures and
        // the audio buffers via gpuResourceID / gpuAddress.
        for texture in useResources {
            encoder.useResource(texture, usage: [.read, .write])
        }
        encoder.useResource(runtime.waveformBuffer, usage: .read)
        encoder.useResource(runtime.spectrumBuffer, usage: .read)

        let threadsPerGrid = MTLSize(width: dispatchTarget.width, height: dispatchTarget.height, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }
}
