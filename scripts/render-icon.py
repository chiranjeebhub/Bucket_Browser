#!/usr/bin/env python3
"""Renders Resources/AppIcon.svg to Resources/AppIcon.png (1024x1024) with soft drop shadows,
and writes every size the Mac app icon set needs to Resources/Assets.xcassets/AppIcon.appiconset.

Needs cairosvg and Pillow: pip install cairosvg pillow
"""
import io
import json
import re
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SVG = (ROOT / "Resources" / "AppIcon.svg").read_text()
SIZE = 1024


def layer(*keep):
    """Renders only the named top-level <g id=...> groups."""
    def strip(match):
        return match.group(0) if match.group(1) in keep else ""
    svg = re.sub(r'<g id="(\w+)".*?</g>', strip, SVG, flags=re.S)
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=SIZE, output_height=SIZE)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def shadow(image, offset, blur, opacity, color=(0, 0, 0)):
    alpha = image.getchannel("A").point(lambda a: int(a * opacity))
    tint = Image.new("RGBA", image.size, color + (0,))
    tint.putalpha(alpha)
    tint = tint.filter(ImageFilter.GaussianBlur(blur))
    moved = Image.new("RGBA", image.size, (0, 0, 0, 0))
    moved.paste(tint, (0, offset), tint)
    return moved


tile = layer("tile")
folder = layer("folder")
cloud = layer("cloud", "arrows")

icon = tile
icon = Image.alpha_composite(icon, shadow(folder, 16, 18, 0.30))
icon = Image.alpha_composite(icon, folder)
icon = Image.alpha_composite(icon, shadow(layer("cloud"), 8, 10, 0.35, (11, 79, 138)))
icon = Image.alpha_composite(icon, cloud)

# Keep the shadow inside the tile so the transparent margin stays clean.
icon.putalpha(Image.composite(icon.getchannel("A"), Image.new("L", icon.size, 0), tile.getchannel("A")))
out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Resources" / "AppIcon.png"
icon.save(out)
print(f"Wrote {out}")

# The icon set scripts/build-app.sh compiles with actool: 16 to 512 points, at 1x and 2x.
ICONSET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ICONSET.mkdir(parents=True, exist_ok=True)
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        pixels = points * scale
        icon.resize((pixels, pixels), Image.LANCZOS).save(ICONSET / name)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
contents = {"images": images, "info": {"author": "xcode", "version": 1}}
(ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
(ICONSET.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print(f"Wrote {ICONSET}")
