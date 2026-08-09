public extension PhosphorConfiguration {
    /// Id used for the output texture and the single pass when a
    /// configuration doesn't name one.
    static let defaultOutput: ResourceID = "image"

    /// Fills in the canonical single-pass shape wherever a configuration
    /// leaves a gap (#51).
    ///
    /// The overwhelmingly common shader is one full-screen procedural pass
    /// writing to one drawable-sized texture, and spelling that out is ten
    /// lines of TOML that never varies. An empty `/* phosphor:environment */`
    /// block should just work.
    ///
    /// Gaps are filled independently, so a configuration that declares only
    /// textures gets a pass, and one that declares only passes gets the
    /// output texture. Anything explicit is left alone — this only ever adds.
    func normalized() -> Self {
        var copy = self

        if copy.textures.isEmpty {
            copy.textures = [Texture(id: copy.output)]
        }

        if copy.passes.isEmpty {
            // Only synthesise a pass if there's something for it to write to;
            // otherwise leave the gap and let validation report it, rather
            // than inventing a pass that names a texture nobody declared.
            if copy.textures.contains(where: { $0.id == copy.output }) {
                copy.passes = [
                    Pass(id: copy.output, textures: [.init(id: copy.output, access: .write)])
                ]
            }
        }

        return copy
    }
}
