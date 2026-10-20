#!/usr/bin/env python3
"""Generate the YappYapp app icon: a violet-blue gradient rounded square
with a white waveform, matching the app's record button styling.

Outputs Resources/AppIcon.icns (via iconutil) and a 1024px PNG.
Run with any Python 3 that has Pillow installed (python3 -m pip install pillow).
"""

import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
SIZE = 1024

# Established YappYapp app-icon colors; intentionally separate from UI tokens.
GRADIENT_TOP = (77, 194, 255)
GRADIENT_BOTTOM = (122, 135, 255)

# Apple's margin convention: icon artwork sits inside ~10% padding
INSET = int(SIZE * 0.098)
CORNER_RADIUS = int((SIZE - 2 * INSET) * 0.225)

# Waveform bar heights as fractions of the card height (symmetric ripple)
BARS = [0.16, 0.30, 0.50, 0.72, 0.50, 0.30, 0.16]
BAR_WIDTH_FRACTION = 0.055
BAR_GAP_FRACTION = 0.045


def diagonal_gradient(size: int) -> Image.Image:
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            r = int(GRADIENT_TOP[0] + (GRADIENT_BOTTOM[0] - GRADIENT_TOP[0]) * t)
            g = int(GRADIENT_TOP[1] + (GRADIENT_BOTTOM[1] - GRADIENT_TOP[1]) * t)
            b = int(GRADIENT_TOP[2] + (GRADIENT_BOTTOM[2] - GRADIENT_TOP[2]) * t)
            pixels[x, y] = (r, g, b)
    return image


def build_icon() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    card_size = SIZE - 2 * INSET
    gradient = diagonal_gradient(card_size)

    mask = Image.new("L", (card_size, card_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, card_size - 1, card_size - 1),
        radius=CORNER_RADIUS,
        fill=255,
    )

    # Soft drop shadow behind the card
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_mask = mask.point(lambda a: int(a * 0.45))
    shadow.paste((30, 40, 90, 255), (INSET, INSET + int(SIZE * 0.02)), shadow_mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(SIZE * 0.025))
    canvas = Image.alpha_composite(canvas, shadow)

    card = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    card.paste(gradient, (INSET, INSET), mask)
    canvas = Image.alpha_composite(canvas, card)

    # Subtle top highlight, clipped to the icon card shape
    full_mask = Image.new("L", (SIZE, SIZE), 0)
    full_mask.paste(mask, (INSET, INSET))

    sheen = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sheen_draw = ImageDraw.Draw(sheen)
    for y in range(INSET, INSET + card_size // 2):
        alpha = int(70 * (1 - (y - INSET) / (card_size / 2)))
        sheen_draw.line([(INSET, y), (INSET + card_size, y)], fill=(255, 255, 255, alpha))

    sheen_alpha = Image.composite(sheen.getchannel("A"), Image.new("L", (SIZE, SIZE), 0), full_mask)
    sheen.putalpha(sheen_alpha)
    canvas = Image.alpha_composite(canvas, sheen)

    # White waveform bars, vertically centered
    draw = ImageDraw.Draw(canvas)
    bar_width = card_size * BAR_WIDTH_FRACTION
    gap = card_size * BAR_GAP_FRACTION
    total_width = len(BARS) * bar_width + (len(BARS) - 1) * gap
    start_x = (SIZE - total_width) / 2
    center_y = SIZE / 2

    for index, height_fraction in enumerate(BARS):
        bar_height = card_size * height_fraction
        x0 = start_x + index * (bar_width + gap)
        draw.rounded_rectangle(
            (x0, center_y - bar_height / 2, x0 + bar_width, center_y + bar_height / 2),
            radius=bar_width / 2,
            fill=(255, 255, 255, 245),
        )

    return canvas


def export(icon: Image.Image) -> None:
    RESOURCES.mkdir(exist_ok=True)
    png_path = RESOURCES / "AppIcon-1024.png"
    icon.save(png_path)
    print(f"wrote {png_path}")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = "" if scale == 1 else "@2x"
                resized = icon.resize((pixels, pixels), Image.LANCZOS)
                resized.save(iconset / f"icon_{points}x{points}{suffix}.png")

        icns_path = RESOURCES / "AppIcon.icns"
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
            check=True,
        )
        print(f"wrote {icns_path}")


if __name__ == "__main__":
    export(build_icon())
