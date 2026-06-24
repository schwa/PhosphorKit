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
/// `.metal` extension is implied, so `named: "Plasma"` resolves
/// `Plasma.metal`. If the resource can't be found or read, a black surface is
/// shown.
public struct PhosphorView: View {
    private let name: String
    private let bundle: Bundle

    public init(named name: String, bundle: Bundle = .main) {
        self.name = name
        self.bundle = bundle
    }

    public var body: some View {
        if let source = Self.loadSource(named: name, bundle: bundle) {
            PhosphorSourceView(source: source)
        } else {
            Color.black
        }
    }

    /// Loads the shader source for `name` from `bundle`, trying the literal
    /// name first then the common `.metal` / `.phosphor` extensions.
    static func loadSource(named name: String, bundle: Bundle) -> String? {
        let candidates: [(String, String?)] = [
            (name, nil),
            ((name as NSString).deletingPathExtension, "metal"),
            ((name as NSString).deletingPathExtension, "phosphor")
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

/// Renders a Phosphor shader from an in-memory source string. Owns the
/// ``PhosphorRuntime`` and drives ``PhosphorPipeline`` each frame.
public struct PhosphorSourceView: View {
    private let source: String

    @State private var runtime = PhosphorRuntime()
    @State private var viewSize: CGSize = .zero
    @State private var loadedSource: String?

    public init(source: String) {
        self.source = source
    }

    public var body: some View {
        Group {
            if viewSize.width > 0, viewSize.height > 0 {
                PhosphorSurfaceView(runtime: runtime, viewSize: viewSize)
            } else {
                Color.black
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
        .task(id: source) {
            guard loadedSource != source else { return }
            loadedSource = source
            runtime.reload(parsed: ParsedPhosphorSource(source: source), assets: [:], audioCapture: nil)
        }
    }
}

/// The Metal render surface plus its mouse-tracking gestures and playback
/// clock. Mounted only once a non-degenerate size is available.
private struct PhosphorSurfaceView: View {
    let runtime: PhosphorRuntime
    let viewSize: CGSize

    @State private var mousePosition: SIMD2<Float> = .zero
    @State private var mouseButtons: UInt32 = 0
    @State private var mouseClickOrigin: SIMD2<Float> = .zero
    @State private var playbackClock = PlaybackClock()

    var body: some View {
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
