#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "App" / "Resources"
APP_ICON = RESOURCES / "AppIcon.png"
MENUBAR_ICON = RESOURCES / "MenuBarIcon.png"
ICONSET = RESOURCES / "AppIcon.iconset"
ICNS = RESOURCES / "AppIcon.icns"
FONT = Path("/Library/Fonts/SF-Pro-Display-Bold.otf")
FALLBACK_FONT = Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf")


def hex_points(cx: float, cy: float, radius: float) -> list[tuple[float, float]]:
    return [
        (
            cx + radius * math.cos(math.radians(angle)),
            cy + radius * math.sin(math.radians(angle)),
        )
        for angle in (-90, -30, 30, 90, 150, 210)
    ]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    font_path = FONT if FONT.exists() else FALLBACK_FONT
    return ImageFont.truetype(str(font_path), size=size)


def text_size(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont) -> tuple[int, int, int, int]:
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    return left, top, right, bottom


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        ratio = y / (size - 1)
        color = tuple(round(top[i] * (1 - ratio) + bottom[i] * ratio) for i in range(3))
        for x in range(size):
            pixels[x, y] = (*color, 255)
    return image


def draw_centered_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    box: tuple[int, int, int, int],
    font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int, int],
) -> None:
    left, top, right, bottom = text_size(draw, text, font)
    width = right - left
    height = bottom - top
    x = box[0] + (box[2] - box[0] - width) / 2 - left
    y = box[1] + (box[3] - box[1] - height) / 2 - top
    draw.text((x, y), text, font=font, fill=fill)


def make_app_icon() -> None:
    scale = 3
    size = 1024
    canvas = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))

    tile_rect = tuple(value * scale for value in (84, 84, 940, 940))
    tile_radius = 170 * scale

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        tile_rect,
        radius=tile_radius,
        fill=(0, 0, 0, 105),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(30 * scale))
    canvas.alpha_composite(shadow, (0, 24 * scale))

    tile_mask = Image.new("L", canvas.size, 0)
    tile_mask_draw = ImageDraw.Draw(tile_mask)
    tile_mask_draw.rounded_rectangle(tile_rect, radius=tile_radius, fill=255)
    tile_fill = vertical_gradient(size * scale, (255, 255, 255), (242, 244, 242))
    canvas.alpha_composite(Image.composite(tile_fill, Image.new("RGBA", canvas.size, (0, 0, 0, 0)), tile_mask))

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        tile_rect,
        radius=tile_radius,
        outline=(255, 255, 255, 230),
        width=8 * scale,
    )

    bubble_points = [
        (512, 230),
        (750, 368),
        (750, 626),
        (630, 696),
        (630, 804),
        (512, 736),
        (274, 598),
        (274, 372),
    ]
    bubble = [(x * scale, y * scale) for x, y in bubble_points]

    bubble_shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    bubble_shadow_draw = ImageDraw.Draw(bubble_shadow)
    bubble_shadow_draw.polygon(bubble, fill=(0, 0, 0, 92))
    bubble_shadow = bubble_shadow.filter(ImageFilter.GaussianBlur(11 * scale))
    canvas.alpha_composite(bubble_shadow, (0, 10 * scale))

    bubble_mask = Image.new("L", canvas.size, 0)
    bubble_mask_draw = ImageDraw.Draw(bubble_mask)
    bubble_mask_draw.polygon(bubble, fill=255)
    bubble_fill = vertical_gradient(size * scale, (16, 43, 77), (9, 31, 55))
    canvas.alpha_composite(Image.composite(bubble_fill, Image.new("RGBA", canvas.size, (0, 0, 0, 0)), bubble_mask))

    shine = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shine_draw = ImageDraw.Draw(shine)
    shine_draw.ellipse(
        (342 * scale, 236 * scale, 748 * scale, 500 * scale),
        fill=(255, 255, 255, 22),
    )
    shine = shine.filter(ImageFilter.GaussianBlur(28 * scale))
    canvas.alpha_composite(Image.composite(shine, Image.new("RGBA", canvas.size, (0, 0, 0, 0)), bubble_mask))

    text_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    text_draw = ImageDraw.Draw(text_layer)
    font = load_font(250 * scale)
    box = (330 * scale, 354 * scale, 696 * scale, 590 * scale)
    draw_centered_text(text_draw, "KC", box, font, (255, 255, 255, 255))
    canvas.alpha_composite(text_layer)

    canvas = canvas.resize((size, size), Image.Resampling.LANCZOS)
    canvas.save(APP_ICON)


def make_menubar_icon() -> None:
    scale = 8
    size = 32
    alpha = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(alpha)

    bubble = [
        (16 * scale, 4 * scale),
        (25 * scale, 9 * scale),
        (25 * scale, 19 * scale),
        (21 * scale, 22 * scale),
        (21 * scale, 28 * scale),
        (16 * scale, 25 * scale),
        (7 * scale, 20 * scale),
        (7 * scale, 9 * scale),
    ]
    draw.polygon(bubble, fill=255)

    font = load_font(9 * scale)
    draw_centered_text(
        draw,
        "KC",
        (7 * scale, 8 * scale, 25 * scale, 19 * scale),
        font,
        0,
    )

    canvas = Image.new("RGBA", alpha.size, (255, 255, 255, 255))
    canvas.putalpha(alpha)
    canvas = canvas.resize((size, size), Image.Resampling.LANCZOS)
    canvas.save(MENUBAR_ICON)


def make_icns() -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)

    source = Image.open(APP_ICON)
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for pixel_size, filename in sizes:
        source.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS).save(ICONSET / filename)

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    shutil.rmtree(ICONSET)


def main() -> None:
    RESOURCES.mkdir(parents=True, exist_ok=True)
    make_app_icon()
    make_menubar_icon()
    make_icns()


if __name__ == "__main__":
    main()
