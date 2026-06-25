import Foundation
import Metal
import MetalKit
import PhosphorCompile
import PhosphorModel
import SwiftUI

/// A self-contained SwiftUI view that loads a `.phosphor`/`.metal` Phosphor
/// shader from a bundle by name and renders it live.
///
/// ```swift
/// PhosphorView(named: "Plasma")
/// ```
///
/// The named resource is looked up in `bundle` (defaulting to `.main`). The
/// `.phosphor` extension is implied, so `named: "Plasma"` resolves
/// `Plasma.phosphor` (falling back to `Plasma.metal`). The source is read in
/// `init`; a missing resource is a programmer error and traps.
///
/// Rendering is raw Metal hosted in an `MTKView` (no MetalSprockets), so an app
/// can embed a `.phosphor` file, link only PhosphorKit, and call
/// `PhosphorView(named:)`.
public struct PhosphorView: View {
    private let parsed: ParsedPhosphorSource

    @State private var runtime = PhosphorRuntime()
    @State private var viewSize: CGSize = .zero
    @State private var loaded = false
    @State private var mousePosition: SIMD2<Float> = .zero
    @State private var mouseButtons: UInt32 = 0
    @State private var mouseClickOrigin: SIMD2<Float> = .zero

    /// Renders an in-memory shader source directly, for callers that already
    /// hold the source string (or previews). The source may carry an embedded
    /// `/* phosphor:environment ... */` front-matter block (legacy `.metal`).
    public init(source: String) {
        self.parsed = ParsedPhosphorSource(source: source)
    }

    /// Renders a parsed/decoded document directly (e.g. the JSON `.phosphor`
    /// format, via `ParsedPhosphorSource(document:)`).
    public init(parsed: ParsedPhosphorSource) {
        self.parsed = parsed
    }

    public var body: some View {
        Group {
            // Only mount the MTKView once we have a non-degenerate size:
            // creating a Metal drawable at zero size returns nil and crashes.
            if viewSize.width > 0, viewSize.height > 0 {
                surface
            } else {
                Color.clear
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
        .task {
            guard !loaded else { return }
            loaded = true
            runtime.reload(parsed: parsed, assets: [:], audioCapture: nil)
        }
    }

    /// The Metal render surface plus its mouse-tracking gestures.
    private var surface: some View {
        MetalRenderView(runtime: runtime) { drawableSize in
            buildUniforms(drawableSize: drawableSize)
        }
        .onContinuousHover { phase in
            if case .active(let point) = phase {
                mousePosition = pixelCoordinate(from: point)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    mousePosition = pixelCoordinate(from: value.location)
                    if mouseButtons & 0b1 == 0 {
                        mouseClickOrigin = pixelCoordinate(from: value.startLocation)
                    }
                    mouseButtons |= 0b1
                }
                .onEnded { _ in
                    mouseButtons &= ~0b1
                }
        )
    }

    private func buildUniforms(drawableSize: CGSize) -> BuiltinUniforms {
        BuiltinUniforms(
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            mouse: mousePosition,
            mouseButtons: mouseButtons,
            mouseClickOrigin: mouseClickOrigin
        )
    }

    private func pixelCoordinate(from point: CGPoint) -> SIMD2<Float> {
        let drawableSize = runtime.currentDrawableSize
        guard viewSize.width > 0, viewSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            return SIMD2<Float>(Float(point.x), Float(point.y))
        }
        let scaleX = Float(drawableSize.width / viewSize.width)
        let scaleY = Float(drawableSize.height / viewSize.height)
        return SIMD2<Float>(Float(point.x) * scaleX, Float(point.y) * scaleY)
    }
}

// MARK: - MTKView host

/// SwiftUI wrapper around an `MTKView` that drives a ``PhosphorRenderer`` once
/// per frame. The `makeUniforms` closure supplies the per-frame builtin
/// uniforms (resolution, mouse, etc.); the coordinator owns the playback clock
/// and frame counter.
private struct MetalRenderView {
    let runtime: PhosphorRuntime
    let makeUniforms: (CGSize) -> BuiltinUniforms

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(runtime: runtime, makeUniforms: makeUniforms)
    }

    @MainActor
    func makeMTKView(_ coordinator: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero, device: runtime.device)
        view.delegate = coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        #if os(macOS)
        view.layer?.isOpaque = false
        #else
        view.isOpaque = false
        #endif
        return view
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let runtime: PhosphorRuntime
        private let makeUniforms: (CGSize) -> BuiltinUniforms
        private let renderer: PhosphorRenderer
        private let commandQueue: MTLCommandQueue?

        private var playbackClock = PlaybackClock()
        private var frameIndex: UInt32 = 0
        private var lastTimestamp: CFTimeInterval?
        private let startTimestamp: CFTimeInterval = CACurrentMediaTime()

        init(runtime: PhosphorRuntime, makeUniforms: @escaping (CGSize) -> BuiltinUniforms) {
            self.runtime = runtime
            self.makeUniforms = makeUniforms
            self.renderer = PhosphorRenderer(device: runtime.device)
            self.commandQueue = runtime.device.makeCommandQueue()
        }

        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            // Free-running wall clock; the playback clock applies pause/reset.
            let now = CACurrentMediaTime()
            let wallTime = Float(now - startTimestamp)
            let delta = Float(now - (lastTimestamp ?? now))
            lastTimestamp = now
            let wall = PlaybackClock.WallClock(time: wallTime, frame: frameIndex, delta: delta)
            let sample = playbackClock.kernelSample(wallClock: wall)
            playbackClock.commit(wallClock: wall)

            var uniforms = makeUniforms(drawableSize)
            uniforms.time = sample.time
            uniforms.timeDelta = sample.delta
            uniforms.frame = sample.frame

            do {
                try renderer.render(
                    runtime: runtime,
                    into: commandBuffer,
                    targetTexture: drawable.texture,
                    drawableSize: drawableSize,
                    builtin: uniforms
                )
            } catch {
                commandBuffer.commit()
                return
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
            frameIndex &+= 1
        }
    }
}

#if os(macOS)
extension MetalRenderView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeMTKView(context.coordinator) }
    func updateNSView(_: MTKView, context _: Context) {}
}
#else
extension MetalRenderView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeMTKView(context.coordinator) }
    func updateUIView(_: MTKView, context _: Context) {}
}
#endif

extension PhosphorView {
    /// Loads a Phosphor shader from `bundle` (defaulting to `.main`) by name.
    ///
    /// The `.phosphor` extension is implied, so `named: "Plasma"` resolves
    /// `Plasma.phosphor` (falling back to `Plasma.metal`). The source is read
    /// eagerly; a missing resource is a programmer error and traps.
    public init(named name: String, bundle: Bundle = .main) {
        guard let url = Self.resolveURL(named: name, bundle: bundle) else {
            fatalError("PhosphorView: no shader resource named '\(name)' found in \(bundle.bundlePath)")
        }
        guard let data = try? Data(contentsOf: url) else {
            fatalError("PhosphorView: failed to read shader resource at \(url.path)")
        }

        // `.phosphor` is the JSON document format (config split from source);
        // anything else (notably `.metal`) is raw source with optional embedded
        // front-matter.
        if url.pathExtension == "phosphor" {
            guard let document = try? PhosphorDocument(jsonData: data) else {
                fatalError("PhosphorView: '\(url.lastPathComponent)' is not a valid .phosphor JSON document")
            }
            self.init(parsed: ParsedPhosphorSource(document: document))
        } else {
            let source = String(decoding: data, as: UTF8.self)
            self.init(source: source)
        }
    }

    /// Resolves the URL for `name` in `bundle`, trying the literal name first
    /// then the `.phosphor` / `.metal` extensions.
    static func resolveURL(named name: String, bundle: Bundle) -> URL? {
        let candidates: [(String, String?)] = [
            (name, nil),
            ((name as NSString).deletingPathExtension, "phosphor"),
            ((name as NSString).deletingPathExtension, "metal")
        ]
        for (resource, ext) in candidates {
            if let url = bundle.url(forResource: resource, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

#Preview("PhosphorView — triangle") {
    let source = """
    /* phosphor:environment
    output = "image"

    [[textures]]
    id = "image"

    [[passes]]
    id = "image"
    textures = [
        { id = "image", access = "write" },
    ]
    */

    uint2 gid [[thread_position_in_grid]];

    // Signed distance to an equilateral triangle of "radius" r, centered at
    // the origin. Negative inside. (iquilezles.org)
    static float sdTriangle(float2 p, float r) {
        const float k = sqrt(3.0);
        p.x = abs(p.x) - r;
        p.y = p.y + r / k;
        if (p.x + k * p.y > 0.0) {
            p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
        }
        p.x -= clamp(p.x, -2.0 * r, 0.0);
        return -length(p) * sign(p.y);
    }

    kernel void image(
        device const Uniforms&     uniforms     [[buffer(0)]],
        device const UserUniforms& userUniforms [[buffer(1)]])
    {
        float2 res = uniforms.resolution;
        // Centered, aspect-correct coordinates in roughly [-1, 1].
        float2 p = (2.0 * float2(gid) - res) / min(res.x, res.y);

        float d = sdTriangle(p, 0.6);
        // Crisp fill with a 2px antialiased edge.
        float aa = 2.0 / min(res.x, res.y);
        float fill = smoothstep(aa, -aa, d);

        float t = uniforms.time;

        // Animated rainbow gradient across the triangle.
        float angle = atan2(p.y, p.x);
        float hue = fract(angle / 6.2831853 + 0.5 + 0.10 * t + 0.25 * length(p));
        float3 tri = hsv(hue, 0.85, 1.0);

        // Glowing outline that pulses.
        float edge = exp(-abs(d) * 18.0) * (0.6 + 0.4 * sin(t * 2.0));
        float3 glow = hsv(fract(hue + 0.5), 0.9, 1.0) * edge;

        // Transparent background: coverage = the triangle fill plus its glow.
        float alpha = clamp(fill + edge, 0.0, 1.0);
        float3 col = tri * fill + glow;
        col = col / (1.0 + col);
        // Premultiplied alpha so the compositor blends the edges correctly.
        uniforms.textures.image.write(float4(col, alpha), gid);
    }
    """
    return PhosphorView(source: source)
        .frame(width: 320, height: 240)
}
