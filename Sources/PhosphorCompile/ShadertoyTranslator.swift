import Foundation
import PhosphorModel

/// Rewrites Shadertoy GLSL into a Phosphor Metal kernel.
///
/// This is the *lexical* half of Shadertoy compatibility: it detects
/// Shadertoy-shaped source, renames built-ins and types, and wraps
/// `mainImage` in a kernel with Phosphor's canonical signature. It does not
/// attempt to reconcile the dialects' semantics — GLSL's implicit float
/// promotion and negative-`mod` behaviour still surface as Metal compile
/// errors or wrong pixels.
///
/// Only the common single-`Image`-pass case is handled. Multi-pass Shadertoy
/// shaders (Buffer A–D), Common tabs, cubemap and sound passes are out of
/// scope and are reported rather than half-translated.
public enum ShadertoyTranslator {
    /// A successful translation.
    public struct Translation: Hashable, Sendable {
        /// A complete Phosphor source, front-matter included.
        public var source: String
        /// Things the translation couldn't do, or did approximately.
        public var diagnostics: [PhosphorDiagnostic]
    }

    /// Shadertoy's entry point. Its presence is what marks a source as
    /// Shadertoy-shaped.
    private static let mainImagePattern =
        #"(?m)^\s*void\s+mainImage\s*\(\s*out\s+vec4\s+(\w+)\s*,\s*in\s+vec2\s+(\w+)\s*\)"#

    /// Whether `source` looks like a Shadertoy shader rather than a Phosphor
    /// one. Deliberately narrow: a source that already declares a Phosphor
    /// kernel is never claimed.
    public static func looksLikeShadertoy(_ source: String) -> Bool {
        guard signature(in: source) != nil else { return false }
        return source.range(of: #"\bkernel\s+void\b"#, options: .regularExpression) == nil
    }

    /// Translates `source` if it looks like Shadertoy; returns nil otherwise.
    public static func translate(_ source: String) -> Translation? {
        guard source.range(of: #"\bkernel\s+void\b"#, options: .regularExpression) == nil else { return nil }

        var diagnostics: [PhosphorDiagnostic] = []
        let tabs = splitTabs(source)
        // Every renderable tab needs its own mainImage; without one there's
        // nothing to translate.
        guard !tabs.renderPasses.isEmpty,
              tabs.renderPasses.allSatisfy({ signature(in: $0.source) != nil }) else {
            return nil
        }

        for pass in unsupportedPasses(in: source) {
            diagnostics.append(.frontMatterParse(
                "Shadertoy '\(pass)' passes aren't supported and were dropped; "
                    + "only Image and Buffer A–D were translated.",
                line: nil
            ))
        }

        // Channel calls are rewritten before `iChannelN` itself moves.
        func rewrite(_ text: String) -> String {
            rewriteTypes(rewriteBuiltins(rewriteChannelCalls(text)))
        }

        // Common is shared by every Shadertoy pass. Phosphor puts all kernels
        // in one file, so it just becomes top-level source.
        var helpers = tabs.common.map(rewrite) ?? ""
        var kernels = ""

        for pass in tabs.renderPasses {
            guard let signature = signature(in: pass.source),
                  let split = splitMainImage(pass.source) else {
                return nil
            }
            helpers += rewrite(split.before) + rewrite(split.after)
            kernels += entryPoint(
                body: rewrite(split.body),
                signature: signature,
                passID: pass.id,
                outputID: pass.id
            )
        }

        // Shadertoy's built-ins are globals; Phosphor's arrive as a kernel
        // parameter. Anything outside mainImage that reads them has no
        // `uniforms` in scope, and there's no lexical fix for that.
        if helpers.contains("uniforms.") {
            diagnostics.append(.frontMatterParse(
                "Shadertoy built-ins (iTime, iResolution, iChannelN, …) are referenced outside mainImage"
                    + (tabs.common == nil ? "" : " (possibly in the Common tab)")
                    + ". Metal has no globals, so those helpers need the built-ins passed in as parameters.",
                line: nil
            ))
        }

        let channels = referencedChannels(in: source)
        if !channels.isEmpty {
            diagnostics.append(.frontMatterParse(
                "iChannel inputs (\(channels.sorted().map { "iChannel\($0)" }.joined(separator: ", "))) "
                    + "were mapped to texture resources; assign assets to them in the front matter.",
                line: nil
            ))
        }

        let bufferIDs = tabs.renderPasses.map(\.id).filter { $0 != Self.imagePassID }
        if !bufferIDs.isEmpty {
            diagnostics.append(.frontMatterParse(
                "Translated \(bufferIDs.count) buffer pass(es): \(bufferIDs.joined(separator: ", ")). "
                    + "Shadertoy stores which buffer each iChannel reads outside the shader source, "
                    + "so those bindings can't be recovered — wire the iChannel textures to the buffer "
                    + "resources by hand in the front matter.",
                line: nil
            ))
        }

        return Translation(
            source: frontMatter(channels: channels, passIDs: tabs.renderPasses.map(\.id))
                + "\n"
                + preamble()
                + helpers
                + kernels,
            diagnostics: diagnostics
        )
    }

    // MARK: - Tabs

    /// Shadertoy's pass id for the final image.
    static let imagePassID = "image"

    /// One Shadertoy editor tab.
    struct Tab: Hashable {
        /// Phosphor pass and texture id: `image`, or `bufferA`…`bufferD`.
        var id: String
        var source: String
    }

    struct Tabs {
        /// The Common tab, if present — source shared by every pass.
        var common: String?
        /// Passes in execution order: buffers first, then image.
        var renderPasses: [Tab]
    }

    /// A line that is nothing but a comment naming a Shadertoy tab, allowing
    /// the decoration people tend to paste around them:
    ///
    ///     // Common
    ///     // === Buffer A ===
    ///     //---- Image ----
    ///
    /// Shadertoy keeps each pass in a separate editor tab, so pasted source
    /// carries no delimiter of its own and something has to be invented.
    private static let tabMarkerPattern =
        #"(?im)^[ \t]*//[ \t=*#\-]*(common|image|buf(?:fer)?[ \t]*([a-d]))[ \t=*#\-]*$"#

    /// Splits `source` at tab markers. With no markers the whole thing is the
    /// Image pass, which is the single-tab case and stays byte-identical to
    /// the pre-multi-pass behaviour.
    static func splitTabs(_ source: String) -> Tabs {
        guard let regex = try? NSRegularExpression(pattern: tabMarkerPattern) else {
            return Tabs(common: nil, renderPasses: [Tab(id: imagePassID, source: source)])
        }
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else {
            return Tabs(common: nil, renderPasses: [Tab(id: imagePassID, source: source)])
        }

        var common: String?
        var buffers: [(letter: String, source: String)] = []
        var image: String?

        for (index, match) in matches.enumerated() {
            let bodyStart = match.range.upperBound
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsSource.length
            let body = nsSource.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            let label = nsSource.substring(with: match.range(at: 1)).lowercased()

            if label == "common" {
                common = (common ?? "") + body
            } else if label == "image" {
                image = (image ?? "") + body
            } else {
                let letter = nsSource.substring(with: match.range(at: 2)).uppercased()
                buffers.append((letter, body))
            }
        }

        // Anything before the first marker belongs to no tab; treat it as
        // Common so a preamble pasted above the markers isn't lost.
        let preambleRange = NSRange(location: 0, length: matches[0].range.location)
        let preamble = nsSource.substring(with: preambleRange)
        if !preamble.trimmed.isEmpty {
            common = preamble + (common ?? "")
        }

        // Shadertoy runs buffers in order, then Image.
        var passes = buffers
            .sorted { $0.letter < $1.letter }
            .map { Tab(id: "buffer\($0.letter)", source: $0.source) }
        if let image {
            passes.append(Tab(id: imagePassID, source: image))
        }
        return Tabs(common: common, renderPasses: passes)
    }

    // MARK: - Detection

    /// The `mainImage` out-colour and in-coordinate parameter names. Only used
    /// to confirm the shape of the entry point; the generated wrapper passes
    /// its own locals through.
    struct Signature: Hashable {
        var fragColor: String
        var fragCoord: String
    }

    static func signature(in source: String) -> Signature? {
        guard let regex = try? NSRegularExpression(pattern: mainImagePattern) else { return nil }
        let nsSource = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: nsSource.length)) else {
            return nil
        }
        return Signature(
            fragColor: nsSource.substring(with: match.range(at: 1)),
            fragCoord: nsSource.substring(with: match.range(at: 2))
        )
    }

    /// Shadertoy entry points other than `mainImage`, which this translator
    /// silently drops rather than mistranslating.
    static func unsupportedPasses(in source: String) -> [String] {
        var found: [String] = []
        if source.range(of: #"\bvoid\s+mainSound\s*\("#, options: .regularExpression) != nil {
            found.append("Sound")
        }
        if source.range(of: #"\bvoid\s+mainCubemap\s*\("#, options: .regularExpression) != nil {
            found.append("Cubemap")
        }
        return found
    }

    /// Indices of the `iChannelN` samplers the source references.
    static func referencedChannels(in source: String) -> Set<Int> {
        var indices: Set<Int> = []
        guard let regex = try? NSRegularExpression(pattern: #"\biChannel(\d)\b"#) else { return indices }
        let nsSource = source as NSString
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match, let index = Int(nsSource.substring(with: match.range(at: 1))) else { return }
            indices.insert(index)
        }
        return indices
    }

    // MARK: - Rewriting

    /// Shadertoy uniform → Phosphor equivalent. `iResolution` is a `vec3` on
    /// Shadertoy (z is the pixel aspect ratio, effectively always 1), so it
    /// gets a float3 with 1 in z rather than a bare `resolution`.
    static let builtinReplacements: [(pattern: String, replacement: String)] = [
        (#"\biTimeDelta\b"#, "uniforms.timeDelta"),
        (#"\biTime\b"#, "uniforms.time"),
        (#"\biFrameRate\b"#, "(1.0f / max(uniforms.timeDelta, 1e-6f))"),
        (#"\biFrame\b"#, "int(uniforms.frame)"),
        (#"\biResolution\b"#, "float3(uniforms.resolution, 1.0f)"),
        (#"\biMouse\b"#, "float4(uniforms.mouse, uniforms.mouseClickOrigin)")
    ]

    static func rewriteBuiltins(_ source: String) -> String {
        var out = source
        for (pattern, replacement) in builtinReplacements {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    /// GLSL type spellings that have a different name in MSL. `vecN`/`matN`
    /// are the common ones; the integer and boolean vectors matter too because
    /// `ivec2` shows up in every `texelFetch`.
    static let typeReplacements: [(pattern: String, replacement: String)] = [
        (#"\bvec2\b"#, "float2"),
        (#"\bvec3\b"#, "float3"),
        (#"\bvec4\b"#, "float4"),
        (#"\bivec2\b"#, "int2"),
        (#"\bivec3\b"#, "int3"),
        (#"\bivec4\b"#, "int4"),
        (#"\buvec2\b"#, "uint2"),
        (#"\buvec3\b"#, "uint3"),
        (#"\buvec4\b"#, "uint4"),
        (#"\bbvec2\b"#, "bool2"),
        (#"\bbvec3\b"#, "bool3"),
        (#"\bbvec4\b"#, "bool4"),
        (#"\bmat2\b"#, "float2x2"),
        (#"\bmat3\b"#, "float3x3"),
        (#"\bmat4\b"#, "float4x4")
    ]

    static func rewriteTypes(_ source: String) -> String {
        var out = source
        for (pattern, replacement) in typeReplacements {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    /// `texture(iChannelN, uv)` → a sample, `texelFetch(iChannelN, c, lod)` →
    /// a read (the lod argument has no equivalent on a non-mipmapped read, so
    /// it's dropped).
    static func rewriteChannelCalls(_ source: String) -> String {
        var out = rewriteCalls(named: ["texelFetch"], in: source) { arguments in
            guard arguments.count >= 2, let channel = channelIndex(arguments[0]) else { return nil }
            return "uniforms.textures.iChannel\(channel).read(uint2(\(arguments[1].trimmed)))"
        }
        out = rewriteCalls(named: ["texture", "texture2D", "textureLod"], in: out) { arguments in
            guard arguments.count >= 2, let channel = channelIndex(arguments[0]) else { return nil }
            return "uniforms.textures.iChannel\(channel)"
                + ".sample(phosphorLinearSampler, \(arguments[1].trimmed))"
        }
        return out
    }

    /// The channel index if `text` is exactly an `iChannelN` reference.
    private static func channelIndex(_ text: String) -> Int? {
        let trimmed = text.trimmed
        guard trimmed.hasPrefix("iChannel") else { return nil }
        return Int(trimmed.dropFirst("iChannel".count))
    }

    /// Finds calls to any of `names` and replaces them using `transform`,
    /// which receives the argument list.
    ///
    /// Regex can't do this: `texelFetch(iChannel0, ivec2(x, y), 0)` has nested
    /// parens and commas, so the arguments have to be split at nesting depth
    /// zero. Returning nil from `transform` leaves the call untouched.
    static func rewriteCalls(
        named names: [String],
        in source: String,
        transform: ([String]) -> String?
    ) -> String {
        var out = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard let (name, openParen) = callStart(at: index, in: source, names: names) else {
                out.append(source[index])
                index = source.index(after: index)
                continue
            }
            guard let (arguments, end) = arguments(from: openParen, in: source),
                  let replacement = transform(arguments) else {
                out.append(contentsOf: source[index..<source.index(index, offsetBy: name.count)])
                index = source.index(index, offsetBy: name.count)
                continue
            }
            out += replacement
            index = end
        }
        return out
    }

    /// If a call to one of `names` starts exactly at `index`, returns the name
    /// and the index of its opening paren.
    private static func callStart(
        at index: String.Index,
        in source: String,
        names: [String]
    ) -> (name: String, openParen: String.Index)? {
        // Longest first, so `texture2D` isn't matched as `texture`.
        for name in names.sorted(by: { $0.count > $1.count }) {
            guard source[index...].hasPrefix(name) else { continue }
            if index > source.startIndex {
                let previous = source[source.index(before: index)]
                if previous.isLetter || previous.isNumber || previous == "_" { continue }
            }
            var cursor = source.index(index, offsetBy: name.count)
            guard cursor < source.endIndex else { continue }
            // Reject identifiers that merely start with the name.
            if source[cursor].isLetter || source[cursor].isNumber || source[cursor] == "_" { continue }
            while cursor < source.endIndex, source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
            }
            guard cursor < source.endIndex, source[cursor] == "(" else { continue }
            return (name, cursor)
        }
        return nil
    }

    /// Splits a parenthesised argument list at depth zero. `openParen` must
    /// address the `(`; the returned index is just past the matching `)`.
    private static func arguments(
        from openParen: String.Index,
        in source: String
    ) -> (arguments: [String], end: String.Index)? {
        var depth = 0
        var current = ""
        var collected: [String] = []
        var index = openParen
        while index < source.endIndex {
            let character = source[index]
            switch character {
            case "(":
                depth += 1
                if depth > 1 { current.append(character) }

            case ")":
                depth -= 1
                if depth == 0 {
                    if !current.trimmed.isEmpty || !collected.isEmpty { collected.append(current) }
                    return (collected, source.index(after: index))
                }
                current.append(character)

            case "," where depth == 1:
                collected.append(current)
                current = ""

            default:
                current.append(character)
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Splits a source around `mainImage`: everything before its signature,
    /// its body (without the outer braces), and everything after.
    // swiftlint:disable:next large_tuple
    static func splitMainImage(_ source: String) -> (before: String, body: String, after: String)? {
        guard let regex = try? NSRegularExpression(pattern: mainImagePattern) else { return nil }
        let nsSource = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: nsSource.length)),
              let signatureRange = Range(match.range, in: source) else {
            return nil
        }
        guard let openBrace = source[signatureRange.upperBound...].firstIndex(of: "{"),
              let closeBrace = matchingBrace(from: openBrace, in: source) else {
            return nil
        }
        return (
            before: String(source[..<signatureRange.lowerBound]),
            body: String(source[source.index(after: openBrace)..<closeBrace]),
            after: String(source[source.index(after: closeBrace)...])
        )
    }

    /// Index of the `}` closing the `{` at `openBrace`.
    private static func matchingBrace(from openBrace: String.Index, in source: String) -> String.Index? {
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1

            case "}":
                depth -= 1
                if depth == 0 { return index }

            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    // MARK: - Generated scaffolding

    static func frontMatter(channels: Set<Int>, passIDs: [String]) -> String {
        var out = """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "image"

        """
        // Buffers get Shadertoy's semantics: a pass reading one sees last
        // frame's contents, which is exactly what `endOfFrame` means.
        for passID in passIDs where passID != imagePassID {
            out += """

            [[textures]]
            id = "\(passID)"
            format = "rgba32Float"
            swap = "endOfFrame"

            """
        }
        for index in channels.sorted() {
            out += """

            [[textures]]
            id = "iChannel\(index)"

            """
        }
        for passID in passIDs {
            out += """

            [[passes]]
            id = "\(passID)"
            textures = [
                { id = "\(passID)", access = "write" },
            """
            for index in channels.sorted() {
                out += "\n    { id = \"iChannel\(index)\", access = \"sample\" },"
            }
            out += "\n]\n"
        }
        out += "*/\n"
        return out
    }

    static func preamble() -> String {
        """
        // Translated from Shadertoy source by Phosphor.

        uint2 gid [[thread_position_in_grid]];

        constexpr sampler phosphorLinearSampler(coord::normalized, address::repeat, filter::linear);


        """
    }

    /// The kernel Phosphor actually runs, with `mainImage`'s body inlined.
    ///
    /// Inlined rather than called because the per-pass `Uniforms` alias is
    /// only `#define`d around the kernel, so a helper function couldn't name
    /// the type. The locals keep the user's own parameter names so the body
    /// compiles unchanged. Shadertoy's `fragCoord` is a pixel centre, hence
    /// the half-pixel offset `gl_FragCoord` also has.
    static func entryPoint(
        body: String,
        signature: Signature,
        passID: String,
        outputID: String
    ) -> String {
        """


        kernel void \(passID)(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            if (gid.x >= uint(uniforms.resolution.x) || gid.y >= uint(uniforms.resolution.y)) {
                return;
            }
            float4 \(signature.fragColor) = float4(0.0f, 0.0f, 0.0f, 1.0f);
            float2 \(signature.fragCoord) = float2(gid) + 0.5f;
        \(body)
            uniforms.textures.\(outputID).write(\(signature.fragColor), gid);
        }

        """
    }
}

extension String {
    // swiftlint:disable:next strict_fileprivate
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
