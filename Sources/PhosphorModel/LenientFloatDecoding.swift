import Foundation

/// Decodes a `Float` from either a float or an integer.
///
/// TOML types `1` and `1.0` differently, and `Codable` won't cross between
/// them, so a hand-written `color = [1, 0, 0, 1]` used to fail the whole
/// front-matter block with `Cannot decode "Float" from 1` (#145). Writing a
/// whole number without a decimal point is an easy thing to do — and the
/// generator does it too — so every float in the configuration accepts both.
///
/// Deliberately one-directional: an integer field still refuses `1.5`, since
/// silently truncating a size or a seed would hide a real mistake.
extension KeyedDecodingContainer {
    func decodeLenientFloat(forKey key: Key) throws -> Float {
        if let value = try? decode(Float.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Float(value) }
        throw DecodingError.typeMismatch(
            Float.self,
            .init(codingPath: codingPath + [key], debugDescription: "Expected a number")
        )
    }

    func decodeLenientFloatArray(forKey key: Key) throws -> [Float] {
        if let values = try? decode([Float].self, forKey: key) { return values }
        if let values = try? decode([Int].self, forKey: key) { return values.map(Float.init) }
        // Mixed arrays like [1, 0.5, 0, 1] decode as neither, so fall back to
        // element-by-element.
        var nested = try nestedUnkeyedContainer(forKey: key)
        var values: [Float] = []
        while !nested.isAtEnd {
            if let value = try? nested.decode(Float.self) {
                values.append(value)
            } else if let value = try? nested.decode(Int.self) {
                values.append(Float(value))
            } else {
                throw DecodingError.typeMismatch(
                    Float.self,
                    .init(codingPath: nested.codingPath, debugDescription: "Expected a number")
                )
            }
        }
        return values
    }
}

extension SingleValueDecodingContainer {
    func decodeLenientFloat() -> Float? {
        if let value = try? decode(Float.self) { return value }
        if let value = try? decode(Int.self) { return Float(value) }
        return nil
    }
}

extension Decoder {
    /// Lenient float for a type whose whole representation is one number.
    func decodeLenientFloat() throws -> Float {
        let container = try singleValueContainer()
        guard let value = container.decodeLenientFloat() else {
            throw DecodingError.typeMismatch(
                Float.self,
                .init(codingPath: codingPath, debugDescription: "Expected a number")
            )
        }
        return value
    }
}
