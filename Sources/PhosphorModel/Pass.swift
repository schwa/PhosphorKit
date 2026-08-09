import Foundation

/// One compute pass. Its `id` is also the name of the Metal `kernel void`
/// function the runtime looks up after compilation.
///
/// A pass declares the textures it touches as a list of
/// ``TextureBinding``s, each pairing a texture id with an MSL access mode
/// (`read` / `sample` / `write` / `read_write`). There's no special
/// notion of an "output" parameter — the runtime determines write targets
/// by scanning the binding list for write-capable access modes.
public struct Pass: Hashable, Sendable, Codable {
    public var id: ResourceID
    public var textures: [TextureBinding]
    public var enabled: Bool
    /// When true the pass runs once at init rather than every frame, and is
    /// re-run only when its state is invalidated: reload/recompile, an
    /// explicit reset, or a texture reallocation (resize). Use it to
    /// precompute something a per-frame pass then reads — a lookup table, a
    /// noise field, a distance transform.
    ///
    /// Not suitable for writing to a ping-pong (`swap`) texture: a single run
    /// only fills the half matching that frame's parity, leaving the other
    /// half blank.
    public var once: Bool

    public init(
        id: ResourceID,
        textures: [TextureBinding] = [],
        enabled: Bool = true,
        once: Bool = false
    ) {
        self.id = id
        self.textures = textures
        self.enabled = enabled
        self.once = once
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case textures
        case enabled
        case once
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ResourceID.self, forKey: .id)
        self.textures = try container.decodeIfPresent([TextureBinding].self, forKey: .textures) ?? []
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.once = try container.decodeIfPresent(Bool.self, forKey: .once) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(textures, forKey: .textures)
        try container.encode(enabled, forKey: .enabled)
        // Omitted when false so round-tripped front-matter stays terse.
        if once {
            try container.encode(once, forKey: .once)
        }
    }

    /// Binds one of the pass's textures by id, with an MSL access mode.
    ///
    /// The binding name in the generated kernel-side `Textures` struct
    /// defaults to `id`, but can be overridden via `name` so a pass can
    /// bind the same texture twice with different access modes (typical
    /// for swap textures: one `write` binding for 'next' parity, one
    /// `read` binding for 'last' parity).
    public struct TextureBinding: Hashable, Codable, Sendable {
        public var id: ResourceID
        public var access: TextureAccess
        /// Optional override for the binding name; when nil, the binding
        /// is named after its `id`.
        public var name: String?

        public init(id: ResourceID, access: TextureAccess, name: String? = nil) {
            self.id = id
            self.access = access
            self.name = name
        }

        /// Effective binding name: `name` if set, else `id.raw`.
        public var effectiveName: String {
            name ?? id.raw
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case access
            case name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(ResourceID.self, forKey: .id)
            self.access = try container.decodeIfPresent(TextureAccess.self, forKey: .access) ?? .read
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(access, forKey: .access)
            if let name {
                try container.encode(name, forKey: .name)
            }
        }
    }
}
