import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
import Testing

/// Every TOML form shown in `docs/Front-Matter-Reference.md` has to actually
/// parse. Documentation that drifts from the parser is worse than none, so
/// the examples in that file are pinned here.
@Suite("Front-matter reference examples")
struct FrontMatterReferenceTests {
    private func parse(_ frontMatter: String) -> ParsedPhosphorSource {
        ParsedPhosphorSource(source: """
        /* phosphor:environment
        \(frontMatter)
        */
        uint2 gid [[thread_position_in_grid]];
        """)
    }

    @Test("Documented texture sizes parse")
    func textureSizes() {
        let parsed = parse("""
        output = "a"

        [[textures]]
        id = "a"
        size = "drawable"

        [[textures]]
        id = "b"
        size = { fixed = { width = 512, height = 512 } }

        [[textures]]
        id = "c"
        size = { scaledDrawable = 0.5 }

        [[passes]]
        id = "a"
        textures = [{ id = "a", access = "write" }]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.map(\.size) == [
            .drawable,
            .fixed(width: 512, height: 512),
            .scaledDrawable(0.5)
        ])
    }

    @Test("Documented init forms parse")
    func textureInit() {
        let parsed = parse("""
        output = "a"

        [[textures]]
        id = "a"
        init = { kind = "zero" }

        [[textures]]
        id = "b"
        init = { kind = "fill", color = [1.0, 0.0, 0.0, 1.0] }

        [[textures]]
        id = "c"
        init = { kind = "image", file = "mandrill" }

        [[textures]]
        id = "d"
        init = { kind = "noise", seed = 42 }

        [[passes]]
        id = "a"
        textures = [{ id = "a", access = "write" }]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.map(\.initialContents) == [
            .zero,
            .fill(SIMD4<Float>(1, 0, 0, 1)),
            .image(file: "mandrill"),
            .noise(seed: 42)
        ])
    }

    /// The feedback snippet in the reference, including the distinct binding
    /// name that makes the previous frame readable.
    @Test("The documented feedback pattern parses")
    func feedback() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"
        swap = "endOfFrame"

        [[passes]]
        id = "image"
        textures = [
            { id = "image", access = "write" },
            { id = "image", access = "read", name = "imagePrev" },
        ]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.first?.swap == .endOfFrame)
        #expect(parsed.configuration.passes.first?.textures.map(\.effectiveName) == ["image", "imagePrev"])
    }

    @Test("Documented uniform declarations parse")
    func uniforms() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]

        [[uniforms]]
        name = "frequency"
        kind = "float"
        default = 6.0
        ui = { slider = { min = 0.5, max = 24.0 } }

        [[uniforms]]
        name = "tint"
        kind = "color"
        default = [0.6, 0.8, 1.0, 1.0]
        ui = "color"
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.uniforms.map(\.name) == ["frequency", "tint"])
        #expect(parsed.configuration.uniforms.first?.ui == .slider(min: 0.5, max: 24.0))
        #expect(parsed.configuration.uniforms.last?.ui == .color)
    }

    @Test("Documented pass flags parse")
    func passFlags() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"

        [[passes]]
        id = "seed"
        once = true
        textures = [{ id = "image", access = "write" }]

        [[passes]]
        id = "image"
        enabled = true
        textures = [{ id = "image", access = "write" }]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.passes.first?.once == true)
        #expect(parsed.configuration.passes.last?.enabled == true)
    }

    /// The reference claims the defaults; if they change, the table is wrong.
    @Test("Documented defaults match the decoder")
    func defaults() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [{ id = "image" , access = "write" }]
        """)
        let texture = parsed.configuration.textures.first
        #expect(texture?.size == .drawable)
        #expect(texture?.format == .rgba32Float)
        #expect(texture?.swap == SwapTiming.none)
        #expect(texture?.initialContents == .zero)
        #expect(parsed.configuration.passes.first?.enabled == true)
        #expect(parsed.configuration.passes.first?.once == false)
        #expect(parsed.configuration.flipY == false)
    }
}

@Suite("Palette usage example", .enabled(if: metalDeviceAvailable))
struct PaletteExampleTests {
    /// The palette snippet in the reference has to parse and compile, since
    /// it's the only place the sampling idiom is written down (#123).
    @Test("The documented palette shader compiles")
    @MainActor
    func paletteExampleCompiles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "image"

        [[textures]]
        id = "palette"
        init = { kind = "image", file = "palette-viridis" }

        [[passes]]
        id = "image"
        textures = [
            { id = "image", access = "write" },
            { id = "palette", access = "sample" },
        ]
        */

        uint2 gid [[thread_position_in_grid]];

        constexpr sampler paletteSampler(coord::normalized, address::clamp_to_edge, filter::linear);

        kernel void image(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            float t = saturate(float(gid.x) / uniforms.resolution.x);
            float3 color = uniforms.textures.palette.sample(paletteSampler, float2(t, 0.5)).rgb;
            uniforms.textures.image.write(float4(color, 1.0), gid);
        }
        """
        let parsed = ParsedPhosphorSource(source: source)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        let errors = ShaderCompiler.compile(parsed: parsed, device: device).diagnostics
        #expect(errors.isEmpty, "\(errors)")
    }
}
