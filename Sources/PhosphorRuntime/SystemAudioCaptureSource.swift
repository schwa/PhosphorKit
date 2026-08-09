#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// Captures the system audio mix with ScreenCaptureKit and writes it into an
/// ``AudioRingStorage``, so shaders can react to whatever is playing rather
/// than to the microphone.
///
/// ScreenCaptureKit is a screen *recording* API, so this needs the Screen
/// Recording permission even though no video is wanted. The stream is
/// configured with the smallest legal frame size and a one-second frame
/// interval; those frames are never subscribed to, so nothing decodes them.
///
/// The alternatives were worse: loopback drivers need the user to install a
/// system extension, and a CoreAudio process tap is more code for a
/// permission prompt that's only marginally less confusing.
@MainActor
final class SystemAudioCaptureSource {
    private let storage: AudioRingStorage
    private var stream: SCStream?
    private var output: StreamOutput?

    nonisolated static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "audio")

    /// Sample rate the stream is configured for. Fixed rather than
    /// negotiated, so the FFT step has a stable bin-to-Hz mapping.
    static let sampleRate: Double = 48_000

    init(storage: AudioRingStorage) {
        self.storage = storage
    }

    enum StartError: Error {
        case noDisplay
        /// Screen Recording is off for this app. `SCShareableContent` is what
        /// reports it — there's no separate authorisation-status API.
        case permissionDenied
    }

    func start() async throws {
        guard stream == nil else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            Self.logger.error("system audio: shareable content unavailable: \(error, privacy: .public)")
            throw StartError.permissionDenied
        }
        guard let display = content.displays.first else { throw StartError.noDisplay }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.channelCount = 1
        configuration.sampleRate = Int(Self.sampleRate)
        // Video is mandatory on the filter but not subscribed to; keep it as
        // cheap as the API allows.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let output = StreamOutput(storage: storage)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        Self.logger.info("system audio capture started")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        output = nil
        do {
            try await stream.stopCapture()
        } catch {
            Self.logger.error("system audio: stop failed: \(error, privacy: .public)")
        }
    }

    /// Receives audio buffers on a ScreenCaptureKit queue — deliberately not
    /// main-actor isolated, since `AudioRingStorage` is the thread-safe seam.
    private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let storage: AudioRingStorage

        init(storage: AudioRingStorage) {
            self.storage = storage
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio else { return }
            let storage = storage
            try? sampleBuffer.withAudioBufferList(blockBufferMemoryAllocator: nil) { list, _ in
                // Mono is requested, so the first buffer is the whole mix.
                guard let buffer = list.first, let data = buffer.mData else { return }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                storage.append(samples: data.bindMemory(to: Float.self, capacity: count), count: count)
            }
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            SystemAudioCaptureSource.logger.error("system audio stream stopped: \(error, privacy: .public)")
        }
    }
}
#endif
