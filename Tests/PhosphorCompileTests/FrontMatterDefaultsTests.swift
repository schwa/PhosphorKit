import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
import Testing

/// An empty front-matter block should produce a working single-pass shader
/// rather than a pile of validation errors (#51).
@Suite("Front-matter defaults")
struct FrontMatterDefaultsTests {
    private func parse(_ frontMatter: String) -> ParsedPhosphorSource {
        ParsedPhosphorSource(source: """
        /* phosphor:environment
        \(frontMatter)
        */
        uint2 gid [[thread_position_in_grid]];
        """)
    }

    @Test("An empty block yields the canonical single-pass shape")
    func emptyBlock() {
        let parsed = parse("")
        #expect(parsed.hasFrontMatter)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.output == "image")
        #expect(parsed.configuration.textures.map(\.id) == ["image"])
        #expect(parsed.configuration.passes.map(\.id) == ["image"])
        #expect(parsed.configuration.passes.first?.textures.map(\.access) == [.write])
    }

    /// Gaps are filled independently, so declaring only half the shape still
    /// works.
    @Test("Declaring only textures still gets a pass")
    func texturesOnly() {
        let parsed = parse("""
        [[textures]]
        id = "image"
        format = "rgba16Float"
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.first?.format == .rgba16Float)
        #expect(parsed.configuration.passes.map(\.id) == ["image"])
    }

    @Test("Declaring only passes still gets the output texture")
    func passesOnly() {
        let parsed = parse("""
        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.map(\.id) == ["image"])
    }

    /// The default output id follows an explicit `output`, so a shader can
    /// rename it without having to spell out the rest.
    @Test("An explicit output name drives the synthesised texture and pass")
    func customOutputName() {
        let parsed = parse(#"output = "screen""#)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.map(\.id) == ["screen"])
        #expect(parsed.configuration.passes.map(\.id) == ["screen"])
    }

    @Test("Explicit declarations are never overwritten")
    func explicitWins() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"
        swap = "endOfFrame"

        [[passes]]
        id = "image"
        textures = [
            { id = "image", access = "write" },
            { id = "image", access = "read", name = "prev" },
        ]
        """)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.textures.first?.swap == .endOfFrame)
        #expect(parsed.configuration.passes.first?.textures.count == 2)
    }

    /// Defaulting must not paper over a genuine mistake: a pass writing to a
    /// texture nobody declared is still an error, not an invitation to invent
    /// one.
    @Test("A pass naming an undeclared texture is still reported")
    func doesNotInventMissingTextures() {
        let parsed = parse("""
        output = "image"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [{ id = "nope", access = "write" }]
        """)
        #expect(!parsed.diagnostics.isEmpty)
    }
}

/// The starter template is what every new document opens with, and it now
/// relies on the defaults rather than spelling the configuration out (#51).
@Suite("Starter template")
struct StarterTemplateTests {
    @Test("Parses cleanly and gets the default single-pass shape")
    func parses() {
        let parsed = ParsedPhosphorSource(source: PhosphorStarterTemplate.source)
        #expect(parsed.hasFrontMatter)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        #expect(parsed.configuration.output == "image")
        #expect(parsed.configuration.passes.map(\.id) == ["image"])
    }

    @Test("Compiles")
    @MainActor
    func compiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSkip.noDevice }
        let parsed = ParsedPhosphorSource(source: PhosphorStarterTemplate.source)
        let errors = ShaderCompiler.compile(parsed: parsed, device: device).diagnostics
        #expect(errors.isEmpty, "\(errors)")
    }
}
