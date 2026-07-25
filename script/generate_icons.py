#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageChops, ImageOps


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "App" / "Resources"
SOURCE_ICON = RESOURCES / "AppIconSource.png"
APP_ICON = RESOURCES / "AppIcon.png"
MENUBAR_ICON = RESOURCES / "MenuBarIcon.png"
ICONSET = RESOURCES / "AppIcon.iconset"
ICNS = RESOURCES / "AppIcon.icns"


def make_app_icon() -> None:
    source = Image.open(SOURCE_ICON).convert("RGBA")
    if source.width != source.height:
        raise ValueError(f"App icon source must be square, got {source.size}")

    bounds = source.getchannel("A").getbbox()
    if bounds is None:
        raise ValueError("App icon source is fully transparent")

    tile = source.crop(bounds)
    tile = ImageOps.contain(tile, (960, 960), Image.Resampling.LANCZOS)
    image = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    image.alpha_composite(
        tile,
        ((image.width - tile.width) // 2, (image.height - tile.height) // 2),
    )
    image.save(APP_ICON)


def make_menubar_icon() -> None:
    source = Image.open(SOURCE_ICON).convert("RGBA")
    luminance = ImageOps.grayscale(source.convert("RGB"))
    symbol_mask = luminance.point(lambda value: 255 if value < 220 else 0)
    symbol_mask = ImageChops.multiply(symbol_mask, source.getchannel("A"))
    bounds = symbol_mask.getbbox()
    if bounds is None:
        raise ValueError("App icon source does not contain a dark symbol")

    symbol_mask = symbol_mask.crop(bounds)
    graphic = ImageOps.contain(symbol_mask, (24, 24), Image.Resampling.LANCZOS)

    image = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    glyph = Image.new("RGBA", graphic.size, (0, 0, 0, 255))
    glyph.putalpha(graphic)
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
