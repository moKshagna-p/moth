#!/usr/bin/env python3
"""Generate Moth's macOS icon from the same simple moth mark used in the UI."""

from pathlib import Path
from PIL import Image, ImageDraw
import math
import subprocess


ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "assets" / "Moth.iconset"
ICONSET.mkdir(parents=True, exist_ok=True)
SIZE = 1024


def cubic(a, b, c, d, steps=36):
    return [
        (
            (1 - t) ** 3 * a[0] + 3 * (1 - t) ** 2 * t * b[0] + 3 * (1 - t) * t * t * c[0] + t**3 * d[0],
            (1 - t) ** 3 * a[1] + 3 * (1 - t) ** 2 * t * b[1] + 3 * (1 - t) * t * t * c[1] + t**3 * d[1],
        )
        for t in (i / steps for i in range(steps + 1))
    ]


def path(draw, sections, color, width, scale, offset):
    for points in sections:
        mapped = [(round(offset[0] + x * scale), round(offset[1] + y * scale)) for x, y in points]
        draw.line(mapped, fill=color, width=width, joint="curve")


background = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
mask = Image.new("L", (SIZE, SIZE))
ImageDraw.Draw(mask).rounded_rectangle((42, 42, 982, 982), radius=220, fill=255)
gradient = Image.new("RGBA", (SIZE, SIZE))
pixels = gradient.load()
for y in range(SIZE):
    for x in range(SIZE):
        glow = max(0, 1 - math.hypot((x - 770) / 940, (y - 200) / 940))
        pixels[x, y] = (int(34 + 25 * glow), int(36 + 17 * glow), int(48 + 27 * glow), 255)
background.paste(gradient, (0, 0), mask)

scale = 12.7
offset = (105, 109)
wing = [
    cubic((32, 24), (23, 12), (11, 10), (5, 14)) + cubic((5, 14), (5, 29), (13, 39), (28, 41)),
    cubic((32, 24), (41, 12), (53, 10), (59, 14)) + cubic((59, 14), (59, 29), (51, 39), (36, 41)),
    cubic((28, 41), (21, 40), (15, 45), (12, 51)) + cubic((12, 51), (22, 54), (29, 50), (32, 44)),
    cubic((36, 41), (43, 40), (49, 45), (52, 51)) + cubic((52, 51), (42, 54), (35, 50), (32, 44)),
]
ink = (234, 226, 224, 255)
draw = ImageDraw.Draw(background)
path(draw, wing, ink, 17, scale, offset)
path(draw, [[(32, 21), (32, 49)], [(28, 18), (23, 12)], [(36, 18), (41, 12)]], ink, 15, scale, offset)
draw.ellipse((offset[0] + 30 * scale, offset[1] + 28 * scale, offset[0] + 34 * scale, offset[1] + 32 * scale), fill=(231, 165, 101, 255))

for size, names in {
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
}.items():
    image = background.resize((size, size), Image.Resampling.LANCZOS)
    for name in names:
        image.save(ICONSET / name)

subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ROOT / "assets" / "Moth.icns")], check=True)
for image in ICONSET.iterdir():
    image.unlink()
ICONSET.rmdir()
