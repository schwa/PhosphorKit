# PhosphorKit

The parse / compile / render core for [Phosphor](http://github.com/schwa/Phosphor),
plus a reusable SwiftUI view for embedding Phosphor shaders in your own apps.

PhosphorKit is the single source of truth for parsing, compiling, and rendering
Phosphor shaders. The Phosphor app builds its editor on top of it.

## Libraries

- **PhosphorModel** — the core data model: configuration, passes, textures,
  uniforms, built-in textures, and the `PhosphorDocument` JSON format for
  `.phosphor` files.
- **PhosphorCompile** — tree-sitter parsing, front-matter handling, source
  assembly, and Metal compilation. Owns `Phosphor.h`.
- **PhosphorRuntime** — the live render pipeline (raw Metal), audio
  capture, and the reusable `PhosphorView`.

## PhosphorView

`PhosphorView` renders a Phosphor shader live, with mouse tracking and a
playback clock.

```swift
import PhosphorRuntime

// Load a bundled shader by name (.phosphor JSON or .metal source).
PhosphorView(named: "Plasma")
PhosphorView(named: "Plasma", bundle: .module)

// Or render an in-memory source / parsed document directly.
PhosphorView(source: metalSourceString)
PhosphorView(parsed: ParsedPhosphorSource(document: document))
```

The view defaults to a transparent background, so shaders that write
transparent pixels composite over whatever is behind them.

## Building

```sh
swift build
swift test
```

## Requirements

- macOS 26 / iOS 26 / visionOS 26

