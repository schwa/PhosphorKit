import Foundation
import Metal
@testable import PhosphorCompile
import PhosphorModel
import Testing

@Suite("Shadertoy translation")
struct ShadertoyTranslatorTests {
    static let plaid = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord)
    {
        vec2 uv = fragCoord / iResolution.xy;
        fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
    }
    """

    // MARK: Detection

    @Test("Shadertoy source is recognised")
    func detectsShadertoy() {
        #expect(ShadertoyTranslator.looksLikeShadertoy(Self.plaid))
    }

    @Test("Plain Metal source is left alone")
    func ignoresMetal() {
        let metal = """
        kernel void image(device const Uniforms& uniforms [[buffer(0)]]) {}
        """
        #expect(!ShadertoyTranslator.looksLikeShadertoy(metal))
        #expect(ShadertoyTranslator.translate(metal) == nil)
    }

    /// A hybrid — Shadertoy signature plus a hand-written kernel — is somebody
    /// mid-port. Claiming it would clobber their work.
    @Test("Source that already has a kernel is never claimed")
    func ignoresHybrid() {
        let hybrid = Self.plaid + "\nkernel void image() {}\n"
        #expect(!ShadertoyTranslator.looksLikeShadertoy(hybrid))
    }

    // MARK: Rewrites

    @Test("Built-in uniforms are renamed")
    func renamesBuiltins() {
        let out = ShadertoyTranslator.rewriteBuiltins("iTime iTimeDelta iFrame iResolution iMouse")
        #expect(out.contains("uniforms.time"))
        #expect(out.contains("uniforms.timeDelta"))
        #expect(out.contains("int(uniforms.frame)"))
        #expect(out.contains("float3(uniforms.resolution, 1.0f)"))
        #expect(out.contains("uniforms.mouse"))
        // Nothing Shadertoy-flavoured should survive.
        #expect(!out.contains("iTime"))
        #expect(!out.contains("iFrame"))
        #expect(!out.contains("iResolution"))
        #expect(!out.contains("iMouse"))
    }

    @Test("Identifiers that merely contain a built-in name are untouched")
    func respectsWordBoundaries() {
        let out = ShadertoyTranslator.rewriteBuiltins("myiTime iTimeless")
        #expect(out == "myiTime iTimeless")
    }

    @Test("GLSL types are renamed")
    func renamesTypes() {
        let out = ShadertoyTranslator.rewriteTypes("vec2 vec3 vec4 ivec2 mat3 mat4")
        #expect(out == "float2 float3 float4 int2 float3x3 float4x4")
    }

    @Test("texture() becomes a sample")
    func rewritesTextureSample() {
        let out = ShadertoyTranslator.rewriteChannelCalls("texture(iChannel0, uv)")
        #expect(out == "uniforms.textures.iChannel0.sample(phosphorLinearSampler, uv)")
    }

    @Test("texelFetch() becomes a read and loses its lod argument")
    func rewritesTexelFetch() {
        let out = ShadertoyTranslator.rewriteChannelCalls("texelFetch(iChannel1, ivec2(3, 4), 0)")
        #expect(out == "uniforms.textures.iChannel1.read(uint2(ivec2(3, 4)))")
    }

    @Test("Referenced channels are collected")
    func collectsChannels() {
        #expect(ShadertoyTranslator.referencedChannels(in: "texture(iChannel0, a) + texture(iChannel2, b)") == [0, 2])
        #expect(ShadertoyTranslator.referencedChannels(in: Self.plaid).isEmpty)
    }

    // MARK: Whole-source translation

    @Test("A translated shader gains front matter and a kernel")
    func producesCompleteSource() throws {
        let translation = try #require(ShadertoyTranslator.translate(Self.plaid))
        #expect(translation.source.hasPrefix("/* phosphor:environment"))
        #expect(translation.source.contains("kernel void image("))
        #expect(!translation.source.contains("mainImage"))
        // mainImage's body is inlined, so its statements survive verbatim
        // apart from the renames.
        #expect(translation.source.contains("float2 uv = fragCoord / float3(uniforms.resolution, 1.0f).xy;"))
    }

    /// Metal has no globals, so a helper reading iTime can't be fixed
    /// lexically. It must be called out rather than left as a raw Metal error.
    @Test("Built-ins used outside mainImage are reported")
    func reportsBuiltinsInHelpers() throws {
        let source = """
        float wobble() { return sin(iTime); }

        void mainImage(out vec4 fragColor, in vec2 fragCoord)
        {
            fragColor = vec4(wobble(), 0.0, 0.0, 1.0);
        }
        """
        let translation = try #require(ShadertoyTranslator.translate(source))
        #expect(translation.diagnostics.contains { diagnostic in
            if case .frontMatterParse(let message, _) = diagnostic { return message.contains("outside mainImage") }
            return false
        })
    }

    @Test("Helper functions that don't touch built-ins are carried over")
    func keepsCleanHelpers() throws {
        let source = """
        float wobble(float x) { return sin(x); }

        void mainImage(out vec4 fragColor, in vec2 fragCoord)
        {
            fragColor = vec4(wobble(iTime), 0.0, 0.0, 1.0);
        }
        """
        let translation = try #require(ShadertoyTranslator.translate(source))
        #expect(translation.source.contains("float wobble(float x)"))
        #expect(translation.diagnostics.isEmpty)
    }

    @Test("Channels become sampled texture resources in the front matter")
    func declaresChannelTextures() throws {
        let source = """
        void mainImage(out vec4 fragColor, in vec2 fragCoord)
        {
            fragColor = texture(iChannel0, fragCoord / iResolution.xy);
        }
        """
        let translation = try #require(ShadertoyTranslator.translate(source))
        #expect(translation.source.contains(#"id = "iChannel0""#))
        #expect(translation.source.contains(#"{ id = "iChannel0", access = "sample" }"#))
        #expect(translation.diagnostics.contains { diagnostic in
            if case .frontMatterParse(let message, _) = diagnostic { return message.contains("iChannel0") }
            return false
        })
    }

    @Test("Unsupported Shadertoy pass types are reported, not silently dropped")
    func reportsUnsupportedPasses() throws {
        let source = Self.plaid + "\nvoid mainSound(int samp, float time) {}\n"
        let translation = try #require(ShadertoyTranslator.translate(source))
        #expect(translation.diagnostics.contains { diagnostic in
            if case .frontMatterParse(let message, _) = diagnostic { return message.contains("Sound") }
            return false
        })
    }

    // MARK: Parser integration

    @Test("Parsing Shadertoy source yields a usable configuration")
    func parserTranslates() {
        let parsed = ParsedPhosphorSource(source: Self.plaid)
        #expect(parsed.hasFrontMatter)
        #expect(parsed.configuration.output == "image")
        #expect(parsed.configuration.passes.map(\.id.raw) == ["image"])
        // The user's text is preserved for the editor; the body is translated.
        #expect(parsed.originalSource == Self.plaid)
        #expect(parsed.body.contains("kernel void image("))
    }

    @Test("Sources with no front matter and no mainImage are unaffected")
    func parserLeavesOtherSourcesAlone() {
        let parsed = ParsedPhosphorSource(source: "// just a comment\n")
        #expect(!parsed.hasFrontMatter)
        #expect(parsed.body == "// just a comment\n")
    }

    // MARK: End to end

    /// The real bar: a translated shader has to survive the Metal compiler.
    @Test("A translated shader compiles")
    @MainActor
    func translatedShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSkip.noDevice }
        let parsed = ParsedPhosphorSource(source: Self.plaid)
        let compiled = ShaderCompiler.compile(parsed: parsed, device: device)
        let compileErrors = compiled.diagnostics.filter { diagnostic in
            if case .compile = diagnostic { return true }
            return false
        }
        #expect(compileErrors.isEmpty, "\(compileErrors)")
    }

    /// Representative Shadertoy idioms, as a running record of what the
    /// lexical translator covers. Add a case here when extending it.
    static let idiomaticShaders: [(name: String, source: String)] = [
        ("uv gradient", plaid),
        ("rotation matrix and loop", """
        void mainImage(out vec4 fragColor, in vec2 fragCoord)
        {
            vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
            mat2 rot = mat2(cos(iTime), -sin(iTime), sin(iTime), cos(iTime));
            uv = rot * uv;
            vec3 col = vec3(0.0);
            for (int i = 0; i < 4; i++) {
                col += vec3(0.1) * float(i) * length(uv);
            }
            fragColor = vec4(col, 1.0);
        }
        """),
        ("fract and mix", """
        void mainImage(out vec4 fragColor, in vec2 fragCoord)
        {
            vec2 uv = fract(fragCoord / iResolution.xy * 8.0);
            vec3 a = vec3(1.0, 0.0, 0.0);
            vec3 b = vec3(0.0, 0.0, 1.0);
            fragColor = vec4(mix(a, b, smoothstep(0.0, 1.0, uv.x)), 1.0);
        }
        """),
        ("helper taking parameters", """
        float box(vec2 p, vec2 b) {
            vec2 d = abs(p) - b;
            return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
        }

        void mainImage(out vec4 fragColor, in vec2 fragCoord)
        {
            vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
            float d = box(uv, vec2(0.3, 0.2));
            fragColor = vec4(vec3(step(d, 0.0)), 1.0);
        }
        """)
    ]

    @Test("Representative Shadertoy idioms translate and compile", arguments: idiomaticShaders)
    @MainActor
    func idiomsCompile(shader: (name: String, source: String)) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSkip.noDevice }
        let parsed = ParsedPhosphorSource(source: shader.source)
        let compileErrors = ShaderCompiler.compile(parsed: parsed, device: device).diagnostics.filter { diagnostic in
            if case .compile = diagnostic { return true }
            return false
        }
        #expect(compileErrors.isEmpty, "\(shader.name): \(compileErrors)")
    }

    @Test("A translated shader that samples a channel compiles")
    @MainActor
    func translatedChannelShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSkip.noDevice }
        let source = """
        void mainImage(out vec4 fragColor, in vec2 fragCoord)
        {
            vec2 uv = fragCoord / iResolution.xy;
            fragColor = texture(iChannel0, uv) * vec4(1.0, 0.5, iTime, 1.0);
        }
        """
        let parsed = ParsedPhosphorSource(source: source)
        let compiled = ShaderCompiler.compile(parsed: parsed, device: device)
        let compileErrors = compiled.diagnostics.filter { diagnostic in
            if case .compile = diagnostic { return true }
            return false
        }
        #expect(compileErrors.isEmpty, "\(compileErrors)")
    }
}
