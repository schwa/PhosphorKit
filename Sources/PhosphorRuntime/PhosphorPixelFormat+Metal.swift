import Metal
import PhosphorModel

/// The Metal mapping for ``PhosphorPixelFormat``.
///
/// Lives here rather than in PhosphorModel so the model stays free of Metal.
/// This switch is the single source of truth for the correspondence; the
/// reverse lookup is derived from it rather than hand-maintained.
extension PhosphorPixelFormat {
    public var metalPixelFormat: MTLPixelFormat {
        switch self {
        case .r8Unorm: return .r8Unorm
        case .rg8Unorm: return .rg8Unorm
        case .rgba8Unorm: return .rgba8Unorm
        case .bgra8Unorm: return .bgra8Unorm
        case .rgba8Unorm_srgb: return .rgba8Unorm_srgb
        case .bgra8Unorm_srgb: return .bgra8Unorm_srgb
        case .r8Snorm: return .r8Snorm
        case .rgba8Snorm: return .rgba8Snorm
        case .r16Unorm: return .r16Unorm
        case .rg16Unorm: return .rg16Unorm
        case .rgba16Unorm: return .rgba16Unorm
        case .r16Float: return .r16Float
        case .rg16Float: return .rg16Float
        case .rgba16Float: return .rgba16Float
        case .r32Float: return .r32Float
        case .rg32Float: return .rg32Float
        case .rgba32Float: return .rgba32Float
        case .rgb10a2Unorm: return .rgb10a2Unorm
        case .rg11b10Float: return .rg11b10Float
        case .rgb9e5Float: return .rgb9e5Float
        }
    }

    /// The Phosphor format for a Metal one, or `nil` if it isn't one Phosphor
    /// can declare.
    public init?(_ metalPixelFormat: MTLPixelFormat) {
        guard let match = Self.allCases.first(where: { $0.metalPixelFormat == metalPixelFormat }) else {
            return nil
        }
        self = match
    }
}
