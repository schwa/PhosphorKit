import Foundation
import PhosphorCompile
import PhosphorModel
import Testing

/// TOML types `1` and `1.0` differently. Every float in the configuration
/// accepts both, because writing a whole number without a decimal point is an
/// easy thing to do by hand and the generator does it too (#145).
@Suite("Whole numbers where floats are expected")
struct LenientFloatTests {
    private func parse(_ frontMatter: String) -> ParsedPhosphorSource {
        ParsedPhosphorSource(source: """
        /* phosphor:environment
        \(frontMatter)
        */
        uint2 gid [[thread_position_in_grid]];
        """)
    }

    @Test("A fill colour written with integers")
    func fillColor() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"
        init = { kind = "fill", color = [1, 0, 0, 1] }

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.first?.initialContents == .fill(SIMD4<Float>(1, 0, 0, 1)))
    }

    /// The awkward case: neither `[Float]` nor `[Int]` decodes a mixed array,
    /// so it needs element-by-element handling.
    @Test("A colour mixing integers and floats")
    func mixedColor() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"
        init = { kind = "fill", color = [1, 0.5, 0, 1] }

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.first?.initialContents == .fill(SIMD4<Float>(1, 0.5, 0, 1)))
    }

    @Test("A float uniform's default, and an integer slider range")
    func uniformDefaults() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]

        [[uniforms]]
        name = "speed"
        kind = "float"
        default = 6
        ui = { slider = { min = 0, max = 24 } }

        [[uniforms]]
        name = "tint"
        kind = "color"
        default = [1, 0, 1, 1]
        ui = "color"
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.uniforms.first?.defaultValue == .float(6))
        #expect(parsed.configuration.uniforms.first?.ui == .slider(min: 0, max: 24))
        #expect(parsed.configuration.uniforms.last?.defaultValue == .float4(SIMD4<Float>(1, 0, 1, 1)))
    }

    @Test("An integer scaledDrawable scale")
    func scaledDrawable() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"
        size = { scaledDrawable = 1 }

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.first?.size == .scaledDrawable(1))
    }

    /// Leniency is one-directional on purpose: truncating a fractional size or
    /// seed would hide a real mistake rather than forgive a typo.
    @Test("Integer fields still reject fractional values")
    func integersStayStrict() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"
        size = { fixed = { width = 512.5, height = 256 } }

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        """)
        #expect(!parsed.diagnostics.isEmpty, "512.5 should not be accepted as a width")
    }

    @Test("A non-number is still rejected")
    func rejectsNonNumbers() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"
        init = { kind = "fill", color = ["red", 0, 0, 1] }

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        """)
        #expect(!parsed.diagnostics.isEmpty)
    }
}
