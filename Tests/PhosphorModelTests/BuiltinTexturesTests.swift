import CoreGraphics
@testable import PhosphorModel
import Testing

struct BuiltinTexturesTests {
    @Test("Every registered built-in resolves to non-empty asset data")
    func allEntriesLoad() {
        for entry in BuiltinTextures.all {
            let asset = BuiltinTextures.asset(named: entry.name)
            #expect(asset != nil, "missing resource for \(entry.name)")
            #expect((asset?.data.count ?? 0) > 0)
        }
    }

    @Test("Built-in assets decode to images at their expected sizes")
    func decodeMandrill() {
        let mandrill = BuiltinTextures.asset(named: "builtin:mandrill")
        let size = mandrill?.pixelSize()
        #expect(size?.width == 512)
        #expect(size?.height == 512)
    }

    @Test("Namespace detection and prefix-optional lookup")
    func namespaceLookup() {
        #expect(BuiltinTextures.isBuiltin("builtin:mandrill"))
        #expect(!BuiltinTextures.isBuiltin("mandrill"))
        // Lookup works with or without the prefix.
        #expect(BuiltinTextures.entry(named: "mandrill")?.name == "builtin:mandrill")
        #expect(BuiltinTextures.entry(named: "builtin:noise-blue")?.id == "noise-blue")
    }

    @Test("Unknown names don't resolve")
    func unknownReturnsNil() {
        #expect(BuiltinTextures.asset(named: "builtin:does-not-exist") == nil)
        #expect(BuiltinTextures.asset(named: "not-a-builtin") == nil)
    }
}

/// The palette LUTs (#123). They're 256x1 so a shader can colourise a scalar
/// without any 1D-texture support, and that shape is load-bearing.
@Suite("Built-in palettes")
struct BuiltinPaletteTests {
    @Test("Palettes are discoverable and all decode")
    func palettesLoad() throws {
        #expect(BuiltinTextures.palettes.count == 8)
        for entry in BuiltinTextures.palettes {
            let asset = try #require(BuiltinTextures.asset(named: entry.name), "\(entry.name) missing")
            let size = try #require(asset.pixelSize(), "\(entry.name) didn't decode")
            #expect(size.width == 256, "\(entry.name) is \(size.width) wide")
            #expect(size.height == 1, "\(entry.name) is \(size.height) tall")
        }
    }

    @Test("Palettes are in the palette- namespace and nothing else is")
    func namespacing() {
        #expect(BuiltinTextures.palettes.allSatisfy { $0.name.hasPrefix("builtin:palette-") })
        let nonPalettes = BuiltinTextures.all.filter { !$0.id.hasPrefix("palette-") }
        #expect(nonPalettes.allSatisfy { !$0.name.contains("palette") })
    }

    /// Pins viridis's endpoints and midpoint to the canonical values, so a
    /// regeneration that silently produced a different (or wrong) colormap
    /// would be caught rather than shipped.
    @Test("Viridis carries the real colormap data")
    func viridisIsGenuine() throws {
        let asset = try #require(BuiltinTextures.asset(named: "builtin:palette-viridis"))
        let image = try #require(asset.makeCGImage())
        var pixels = [UInt8](repeating: 0, count: image.width * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: image.width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: 1))

        func rgb(_ index: Int) -> [UInt8] { Array(pixels[(index * 4)..<(index * 4 + 3)]) }
        #expect(rgb(0) == [68, 1, 84], "first stop was \(rgb(0))")
        #expect(rgb(128) == [33, 145, 140], "midpoint was \(rgb(128))")
        #expect(rgb(255) == [253, 231, 37], "last stop was \(rgb(255))")
    }
}
