import Metal
@testable import PhosphorRuntime
import Testing

/// #3: a frame's audio buffers must not be rewritten while later frames are
/// prepared, since that frame may still be reading them on the GPU.
@Suite("Audio buffers", .enabled(if: metalDeviceAvailable))
struct AudioBufferTests {
    @Test("Next frame's write leaves the previous frame's buffers untouched")
    @MainActor
    func previousFrameUntouched() {
        let runtime = PhosphorRuntime()

        runtime.writeAudioBuffers()
        let waveform = runtime.waveformBuffer
        let spectrum = runtime.spectrumBuffer
        // Stand-in for real audio data the in-flight frame is reading.
        waveform.contents().storeBytes(of: Float(0.5), as: Float.self)
        spectrum.contents().storeBytes(of: Float(0.25), as: Float.self)

        runtime.writeAudioBuffers()
        #expect(waveform.contents().load(as: Float.self) == 0.5)
        #expect(spectrum.contents().load(as: Float.self) == 0.25)
    }
}
