import Foundation
import MetalSprockets
import MetalSprocketsUI
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
public struct PhosphorView: View {
    private let source: String

    @State private var runtime = PhosphorRuntime()
    @State private var viewSize: CGSize = .zero
    @State private var loaded = false
    @State private var mousePosition: SIMD2<Float> = .zero
    @State private var mouseButtons: UInt32 = 0
    @State private var mouseClickOrigin: SIMD2<Float> = .zero
    @State private var playbackClock = PlaybackClock()

    /// Renders an in-memory shader source directly, for callers that already
    /// hold the source string (or previews).
    public init(source: String) {
        self.source = source
    }

    public var body: some View {
        Group {
            // Only mount the MTKView once we have a non-degenerate size:
            // creating a Metal drawable at zero size returns nil and crashes.
            if viewSize.width > 0, viewSize.height > 0 {
                surface
            } else {
                Color.black
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
        .task {
            guard !loaded else { return }
            loaded = true
            runtime.reload(parsed: ParsedPhosphorSource(source: source), assets: [:], audioCapture: nil)
        }
    }

    /// The Metal render surface plus its mouse-tracking gestures and playback
    /// clock.
    private var surface: some View {
        RenderView { context, drawableSize in
            PhosphorPipeline(
                runtime: runtime,
                uniforms: buildUniforms(context: context, drawableSize: drawableSize),
                drawableSize: drawableSize
            )
            .onWorkloadEnter { _ in
                playbackClock.commit(wallClock: wallClock(from: context))
            }
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

    private func buildUniforms(context: RenderViewContext, drawableSize: CGSize) -> BuiltinUniforms {
        let sample = playbackClock.kernelSample(wallClock: wallClock(from: context))
        return BuiltinUniforms(
            time: sample.time,
            timeDelta: sample.delta,
            frame: sample.frame,
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            mouse: mousePosition,
            mouseButtons: mouseButtons,
            mouseClickOrigin: mouseClickOrigin
        )
    }

    private func wallClock(from context: RenderViewContext) -> PlaybackClock.WallClock {
        PlaybackClock.WallClock(
            time: context.frameUniforms.time,
            frame: context.frameUniforms.index,
            delta: Float(context.frameUniforms.deltaTime)
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

extension PhosphorView {
    /// Loads a Phosphor shader from `bundle` (defaulting to `.main`) by name.
    ///
    /// The `.phosphor` extension is implied, so `named: "Plasma"` resolves
    /// `Plasma.phosphor` (falling back to `Plasma.metal`). The source is read
    /// eagerly; a missing resource is a programmer error and traps.
    public init(named name: String, bundle: Bundle = .main) {
        guard let source = Self.loadSource(named: name, bundle: bundle) else {
            fatalError("PhosphorView: no shader resource named '\(name)' found in \(bundle.bundlePath)")
        }
        self.init(source: source)
    }

    /// Loads the shader source for `name` from `bundle`, trying the literal
    /// name first then the `.phosphor` / `.metal` extensions.
    static func loadSource(named name: String, bundle: Bundle) -> String? {
        let candidates: [(String, String?)] = [
            (name, nil),
            ((name as NSString).deletingPathExtension, "phosphor"),
            ((name as NSString).deletingPathExtension, "metal")
        ]
        for (resource, ext) in candidates {
            if let url = bundle.url(forResource: resource, withExtension: ext),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
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

        // Subtly shifting dark backdrop so it's not flat black.
        float3 bg = hsv(fract(0.6 + 0.03 * t), 0.5, 0.12);

        // Glowing outline that pulses.
        float edge = exp(-abs(d) * 18.0) * (0.6 + 0.4 * sin(t * 2.0));
        float3 glow = hsv(fract(hue + 0.5), 0.9, 1.0) * edge;

        float3 col = mix(bg, tri, fill) + glow;
        col = col / (1.0 + col);
        uniforms.textures.image.write(float4(col, 1.0), gid);
    }
    """
    return PhosphorView(source: source)
        .frame(width: 320, height: 240)
}
