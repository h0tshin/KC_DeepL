#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "App" / "Resources"
SOURCE_ICON = RESOURCES / "AppIconSource.png"
APP_ICON = RESOURCES / "AppIcon.png"
MENUBAR_ICON = RESOURCES / "MenuBarIcon.png"
ICONSET = RESOURCES / "AppIcon.iconset"
ICNS = RESOURCES / "AppIcon.icns"


def foreground_bounds(image: Image.Image, padding: int = 18) -> tuple[int, int, int, int]:
    rgb = image.convert("RGB")
    white = Image.new("RGB", rgb.size, (255, 255, 255))
    difference = ImageChops.difference(rgb, white).convert("L")
    mask = difference.point(lambda value: 255 if value > 18 else 0)
    bounds = largest_component_bounds(mask)
    if bounds is None:
        return (0, 0, image.width, image.height)

    left, top, right, bottom = bounds
    return (
        max(0, left - padding),
        max(0, top - padding),
        min(image.width, right + padding),
        min(image.height, bottom + padding),
    )


def largest_component_bounds(mask: Image.Image) -> tuple[int, int, int, int] | None:
    scale = 256 / max(mask.size)
    small_size = (
        max(1, round(mask.width * scale)),
        max(1, round(mask.height * scale)),
    )
    small = mask.resize(small_size, Image.Resampling.NEAREST)
    pixels = small.load()
    visited: set[tuple[int, int]] = set()
    best: tuple[int, int, int, int, int] | None = None

    for y in range(small.height):
        for x in range(small.width):
            if (x, y) in visited or pixels[x, y] == 0:
                continue

            stack = [(x, y)]
            visited.add((x, y))
            count = 0
            left = right = x
            top = bottom = y

            while stack:
                current_x, current_y = stack.pop()
                count += 1
                left = min(left, current_x)
                right = max(right, current_x)
                top = min(top, current_y)
                bottom = max(bottom, current_y)

                for next_x, next_y in (
                    (current_x + 1, current_y),
                    (current_x - 1, current_y),
                    (current_x, current_y + 1),
                    (current_x, current_y - 1),
                ):
                    if (
                        next_x < 0
                        or next_y < 0
                        or next_x >= small.width
                        or next_y >= small.height
                        or (next_x, next_y) in visited
                        or pixels[next_x, next_y] == 0
                    ):
                        continue

                    visited.add((next_x, next_y))
                    stack.append((next_x, next_y))

            if best is None or count > best[0]:
                best = (count, left, top, right + 1, bottom + 1)

    if best is None:
        return None

    _, left, top, right, bottom = best
    x_scale = mask.width / small.width
    y_scale = mask.height / small.height
    return (
        max(0, int(left * x_scale)),
        max(0, int(top * y_scale)),
        min(mask.width, int(right * x_scale)),
        min(mask.height, int(bottom * y_scale)),
    )


def make_app_icon() -> None:
    source = Image.open(SOURCE_ICON).convert("RGBA")
    remove_source_watermark(source)
    crop = source.crop(foreground_bounds(source))

    size = 1024
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle((82, 82, 942, 942), radius=178, fill=(0, 0, 0, 92))
    shadow = shadow.filter(ImageFilter.GaussianBlur(24))
    canvas.alpha_composite(shadow, (0, 18))

    tile_mask = Image.new("L", (size, size), 0)
    tile_draw = ImageDraw.Draw(tile_mask)
    tile_draw.rounded_rectangle((72, 72, 952, 952), radius=182, fill=255)

    graphic = ImageOps.contain(crop, (910, 910), Image.Resampling.LANCZOS)
    x = (size - graphic.width) // 2
    y = (size - graphic.height) // 2
    tile = Image.new("RGBA", (size, size), (248, 249, 248, 255))
    tile.alpha_composite(graphic, (x, y))
    canvas.alpha_composite(Image.composite(tile, Image.new("RGBA", (size, size), (0, 0, 0, 0)), tile_mask))
    canvas.save(APP_ICON)


def remove_source_watermark(image: Image.Image) -> None:
    width, height = image.size
    draw = ImageDraw.Draw(image)
    draw.rectangle(
        (
            round(width * 0.87),
            round(height * 0.83),
            width,
            height,
        ),
        fill=(255, 255, 255, 255),
    )


def make_menubar_icon() -> None:
    source = Image.open(SOURCE_ICON).convert("RGBA")
    remove_source_watermark(source)
    crop = source.crop(foreground_bounds(source, padding=4))
    graphic = ImageOps.contain(crop, (30, 30), Image.Resampling.LANCZOS)

    rgb = graphic.convert("RGB")
    white = Image.new("RGB", rgb.size, (255, 255, 255))
    difference = ImageChops.difference(rgb, white).convert("L")
    alpha = difference.point(lambda value: 255 if value > 22 else 0)

    image = Image.new("RGBA", (32, 32), (255, 255, 255, 0))
    glyph = Image.new("RGBA", graphic.size, (255, 255, 255, 255))
    glyph.putalpha(alpha)
    image.alpha_composite(glyph, ((32 - graphic.width) // 2, (32 - graphic.height) // 2))
    image.save(MENUBAR_ICON)


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
    if not SOURCE_ICON.exists():
        raise FileNotFoundError(f"Missing source icon image: {SOURCE_ICON}")

    RESOURCES.mkdir(parents=True, exist_ok=True)
    make_app_icon()
    make_menubar_icon()
    make_icns()


if __name__ == "__main__":
    main()
