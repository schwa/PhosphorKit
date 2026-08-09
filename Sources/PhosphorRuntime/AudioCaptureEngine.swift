import AVFoundation
import Foundation
import Observation
import os

/// Owns a single AVAudioEngine input tap and a small ring buffer of the most
/// recent mono Float32 audio samples. Exposes the latest `N` samples on
/// demand so the runtime can copy them into the GPU waveform buffer each
/// frame.
///
/// One instance per app — provided via the SwiftUI configuration so the
/// document UI can drive the toggle from a toolbar item.
@preconcurrency
@MainActor
@Observable
public final class AudioCaptureEngine {
    /// Where the samples come from.
    public enum Source: String, Hashable, Codable, Sendable, CaseIterable {
        /// The default input device.
        case microphone
        /// The system audio mix — whatever is playing out of the speakers.
        /// macOS only, and needs the Screen Recording permission.
        case systemAudio
    }

    /// User-facing on/off. Setting to `true` starts capture (after requesting
    /// permission); setting to `false` stops it and zeros the ring buffer.
    public var isEnabled: Bool = false {
        didSet {
            guard oldValue != isEnabled else { return }
            Self.logger.info("isEnabled \(oldValue, privacy: .public) -> \(self.isEnabled, privacy: .public)")
            if isEnabled {
                Task { await startIfPermitted() }
            } else {
                stop()
            }
        }
    }

    /// Which input to capture. Changing it while enabled restarts capture on
    /// the new source, and clears any denial recorded for the old one — the
    /// two sources have unrelated permissions.
    public var source: Source = .microphone {
        didSet {
            guard oldValue != source else { return }
            Self.logger.info("source \(oldValue.rawValue, privacy: .public) -> \(self.source.rawValue, privacy: .public)")
            isPermissionDenied = false
            guard isEnabled else { return }
            stop()
            Task { await startIfPermitted() }
        }
    }

    /// `true` once we've asked the system for permission and been denied.
    /// The toolbar should disable its toggle with explanatory help text.
    public private(set) var isPermissionDenied: Bool = false

    /// Reflects whether the underlying AVAudioEngine is currently running.
    public private(set) var isRunning: Bool = false

    /// Number of mono Float32 samples held by the ring buffer. Matches the
    /// runtime's `waveformBuffer` length so a single memcpy fills it each
    /// frame.
    public let sampleCount: Int

    private let engine = AVAudioEngine()
    #if os(macOS)
    @ObservationIgnored
    private var systemAudioSource: SystemAudioCaptureSource?
    #endif
    /// Holds the ring buffer + lock + running flag. Lives in its own non-
    /// actor-isolated type so the AVAudioEngine tap block (which runs on a
    /// real-time audio thread, not the main actor) can write into it
    /// without tripping Swift Concurrency's isolation assertions.
    @ObservationIgnored
    private let storage: AudioRingStorage
    /// Sample-rate the input tap is using. We retain it so the FFT step
    /// (#35) can convert bin indices to Hz.
    public private(set) var sampleRate: Double = 0

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "audio")

    public init(sampleCount: Int = 1_024) {
        self.sampleCount = sampleCount
        self.storage = AudioRingStorage(sampleCount: sampleCount)
    }

    /// Snapshot of `isRunning` safe to read from any thread (including the
    /// Metal render loop).
    nonisolated public var isRunningNonisolated: Bool { storage.isRunning }

    // MARK: - Snapshot

    /// Copies the most-recent `sampleCount` samples into `destination` in
    /// the order they were captured (oldest → newest).
    nonisolated public func copyLatestSamples(into destination: UnsafeMutablePointer<Float>) {
        storage.copyLatestSamples(into: destination)
    }

    // MARK: - Engine lifecycle

    private func startIfPermitted() async {
        #if os(macOS)
        if source == .systemAudio {
            await startSystemAudio()
            return
        }
        #endif
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.logger.info("startIfPermitted: status=\(String(describing: status), privacy: .public)")
        switch status {
        case .notDetermined:
            Self.logger.info("requesting microphone access…")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Self.logger.info("microphone access \(granted ? "granted" : "denied", privacy: .public)")
            if granted {
                start()
            } else {
                isPermissionDenied = true
                isEnabled = false
            }

        case .authorized:
            Self.logger.info("microphone already authorized")
            start()

        case .denied, .restricted:
            Self.logger.error("microphone permission denied or restricted at system level")
            isPermissionDenied = true
            isEnabled = false

        @unknown default:
            Self.logger.error("microphone permission unknown status")
            isPermissionDenied = true
            isEnabled = false
        }
    }

    private func start() {
        guard !engine.isRunning else { return }
        Self.logger.info("start()")
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        Self.logger.info("input format: sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")

        storage.reset()

        inputNode.removeTap(onBus: 0)

        do {
            try installNonisolatedTap(on: inputNode, format: format, storage: storage)
            try engine.start()
            isRunning = true
            storage.isRunning = true
            Self.logger.info("audio engine started, sampleRate=\(format.sampleRate, privacy: .public)")
        } catch {
            Self.logger.error("audio engine start failed: \(error, privacy: .public)")
            isRunning = false
            storage.isRunning = false
            isEnabled = false
        }
    }

    #if os(macOS)
    /// ScreenCaptureKit has no authorisation-status API to consult up front,
    /// so "is it permitted" and "start it" are the same call: asking for
    /// shareable content is what prompts, and what fails when denied.
    private func startSystemAudio() async {
        let source = systemAudioSource ?? SystemAudioCaptureSource(storage: storage)
        systemAudioSource = source
        storage.reset()
        do {
            try await source.start()
            sampleRate = SystemAudioCaptureSource.sampleRate
            isRunning = true
            storage.isRunning = true
        } catch {
            Self.logger.error("system audio start failed: \(error, privacy: .public)")
            isPermissionDenied = true
            isRunning = false
            storage.isRunning = false
            isEnabled = false
            systemAudioSource = nil
        }
    }
    #endif

    private func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        #if os(macOS)
        if let systemAudioSource {
            self.systemAudioSource = nil
            Task { await systemAudioSource.stop() }
        }
        #endif
        isRunning = false
        storage.isRunning = false
        storage.reset()
    }
}

/// Installs the AVAudioEngine tap block as a free, fully-nonisolated function
/// so the closure created here does NOT inherit `@MainActor` isolation from
/// ``AudioCaptureEngine``. The audio engine invokes the tap block on a
/// real-time audio thread; if the closure were main-actor-isolated, Swift
/// Concurrency's executor-check would fire and crash the process.
///
/// On macOS 27+ the `@Sendable` `tapProvider` closure handed to
/// `installAudioTap` is free of any actor isolation, so the executor-check
/// never fires. On macOS 26 we fall back to the legacy `installTap`.
private func installNonisolatedTap(on inputNode: AVAudioInputNode, format: AVAudioFormat, storage: AudioRingStorage) throws {
    if #available(macOS 27, iOS 27, visionOS 27, *) {
        try inputNode.installAudioTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            storage.append(buffer: buffer)
        }
    } else {
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            storage.append(buffer: buffer)
        }
    }
}

/// Non-actor-isolated ring buffer + lock + flag, holding the bits the
/// AVAudioEngine tap block needs to touch without going through any actor.
final class AudioRingStorage: @unchecked Sendable {
    let sampleCount: Int
    private let lock = NSLock()
    private let ring: UnsafeMutableBufferPointer<Float>
    private var head: Int = 0
    /// Treat as atomic-ish: only written from main, read from anywhere.
    /// NSLock-guarded inside `copyLatestSamples` but raw elsewhere; small
    /// races on this flag are benign.
    var isRunning: Bool = false

    init(sampleCount: Int) {
        self.sampleCount = sampleCount
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: sampleCount)
        buffer.initialize(repeating: 0)
        self.ring = buffer
    }

    deinit {
        ring.deinitialize()
        ring.deallocate()
    }

    func reset() {
        lock.lock()
        ring.update(repeating: 0)
        head = 0
        lock.unlock()
    }

    func copyLatestSamples(into destination: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        let base = ring.baseAddress!
        let tail = sampleCount - head
        destination.update(from: base.advanced(by: head), count: tail)
        if head > 0 {
            destination.advanced(by: tail).update(from: base, count: head)
        }
    }

    @available(macOS 27, iOS 27, visionOS 27, *)
    func append(buffer: AVReadOnlyAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        guard case .float(let samples) = buffer.channelData(0) else { return }
        let base = ring.baseAddress!
        lock.lock()
        defer { lock.unlock() }
        var src = 0
        while src < frameCount {
            let remaining = frameCount - src
            let writable = min(remaining, sampleCount - head)
            for i in 0..<writable {
                base[head + i] = samples[src + i]
            }
            head = (head + writable) % sampleCount
            src += writable
        }
    }

    func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        append(samples: channelData[0], count: Int(buffer.frameLength))
    }

    /// Core append. The system-audio source hands over raw frames out of a
    /// `CMSampleBuffer`'s audio buffer list, which isn't an `AVAudioPCMBuffer`.
    func append(samples: UnsafePointer<Float>, count frameCount: Int) {
        guard frameCount > 0 else { return }
        let base = ring.baseAddress!
        lock.lock()
        defer { lock.unlock() }
        var src = 0
        while src < frameCount {
            let remaining = frameCount - src
            let writable = min(remaining, sampleCount - head)
            base.advanced(by: head).update(from: samples + src, count: writable)
            head = (head + writable) % sampleCount
            src += writable
        }
    }
}
