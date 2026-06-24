import Foundation

/// The on-disk representation of a `.phosphor` file: a JSON blob that keeps the
/// shader ``configuration`` (front-matter) separate from the Metal ``source``.
///
/// This is the canonical format for the `.phosphor` UTType. The legacy `.metal`
/// format — Metal source with an embedded `/* phosphor:environment ... */` TOML
/// comment — is unchanged and handled separately.
public struct PhosphorDocument: Hashable, Sendable, Codable {
    /// Current on-disk format version. Bump when the shape changes; readers
    /// should reject (or migrate) unknown future versions.
    public static let currentVersion = 1

    /// On-disk format version.
    public var version: Int
    /// The shader configuration (output, passes, textures, uniforms).
    public var configuration: PhosphorConfiguration
    /// The Metal kernel source, with no embedded front-matter.
    public var source: String

    public init(version: Int = PhosphorDocument.currentVersion, configuration: PhosphorConfiguration, source: String) {
        self.version = version
        self.configuration = configuration
        self.source = source
    }

    /// Decodes a document from its JSON `data` representation.
    public init(jsonData data: Data) throws {
        self = try JSONDecoder().decode(PhosphorDocument.self, from: data)
    }

    /// Encodes this document to pretty-printed, key-sorted JSON.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
