#!/usr/bin/env -S uv run --with matplotlib --with pillow --script
"""Regenerate the built-in colour-palette textures.

Palettes ship as 256x1 PNGs (see Phosphor #123): a shader samples one with a
scalar at `uv.x` and `y = 0.5`, which needs no 1D-texture support in the model
or the generated header.

Provenance matters here, so the data is taken from matplotlib rather than
eyeballed:

  viridis, magma, inferno, plasma, cividis
      Released into the public domain (CC0) by their authors. viridis/magma/
      inferno/plasma by Nathaniel J. Smith and Stefan van der Walt; cividis by
      Nunez, Anderton and Renslow.

  gray, hsv, hot
      Classic formulaic ramps with no novel authorship.

Deliberately not shipped: turbo, which is Google's and Apache-2.0 licensed.
Bundling it means carrying an attribution requirement, which is a call for a
human to make.

Usage:
    ./Scripts/generate-palettes.py
"""

from pathlib import Path

import matplotlib
from PIL import Image

WIDTH = 256
DESTINATION = Path(__file__).resolve().parent.parent / "Sources/PhosphorModel/Resources/BuiltinTextures"

# matplotlib name -> shipped filename stem
PALETTES = {
    "viridis": "palette-viridis",
    "magma": "palette-magma",
    "inferno": "palette-inferno",
    "plasma": "palette-plasma",
    "cividis": "palette-cividis",
    "gray": "palette-grayscale",
    "hsv": "palette-hsv",
    "hot": "palette-heat",
}


def main() -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name, stem in PALETTES.items():
        colormap = matplotlib.colormaps[name]
        pixels = [
            tuple(round(channel * 255) for channel in colormap(index / (WIDTH - 1))[:3])
            for index in range(WIDTH)
        ]
        image = Image.new("RGB", (WIDTH, 1))
        image.putdata(pixels)
        path = DESTINATION / f"{stem}.png"
        image.save(path, optimize=True)
        print(f"wrote {path.relative_to(DESTINATION.parent.parent.parent.parent)}")


if __name__ == "__main__":
    main()
