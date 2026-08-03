#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageOps


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "App" / "Resources"
SOURCE_ICON = RESOURCES / "AppIconSource.png"
APP_ICON = RESOURCES / "AppIcon.png"
MENUBAR_ICON = RESOURCES / "MenuBarIcon.png"
ICONSET = RESOURCES / "AppIcon.iconset"
ICNS = RESOURCES / "AppIcon.icns"
POPCLIP_ICON = (
    ROOT
    / "Integrations"
    / "PopClip"
    / "KCDeepL.popclipext"
    / "kcdeepl-popclip.png"
)

APP_ICON_SIZE = 1024
APP_ICON_CONTENT_SIZE = 960
MENUBAR_CANVAS_SIZE = 32
MENUBAR_SYMBOL_SIZE = 24
POPCLIP_CANVAS_SIZE = 1024
POPCLIP_SYMBOL_SIZE = 800
SYMBOL_SAFE_AREA_INSET_RATIO = 0.10
# Full-tile artwork usually fills most of its source canvas (the rounded
# background is the alpha shape), while a supplied transparent logo keeps
# intentional outer padding. Crop only the former so that transparent-logo
# composition is preserved in the generated app icon.
SOURCE_CROP_MIN_COVERAGE = 0.65


def square_image(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    if image.width != image.height:
        raise ValueError(f"Icon image must be square, got {image.size}: {path}")
    return image


def prepare_source_icon(design_path: Path) -> None:
    design = square_image(design_path)
    if min(design.size) < APP_ICON_SIZE:
        raise ValueError(
            f"Icon design must be at least {APP_ICON_SIZE} px, got {design.size}"
        )

    rounded_mask = Image.new("L", design.size, 0)
    radius = round(design.width * 0.22)
    ImageDraw.Draw(rounded_mask).rounded_rectangle(
        (0, 0, design.width - 1, design.height - 1),
        radius=radius,
        fill=255,
    )
    design.putalpha(
        ImageChops.multiply(design.getchannel("A"), rounded_mask)
    )
    SOURCE_ICON.parent.mkdir(parents=True, exist_ok=True)
    design.save(SOURCE_ICON)


def symbol_mask(source: Image.Image) -> Image.Image:
    luminance = ImageOps.grayscale(source.convert("RGB"))

    def mask_value(value: int) -> int:
        background_cutoff = 238
        opaque_cutoff = 216
        if value >= background_cutoff:
            return 0
        if value <= opaque_cutoff:
            return 255
        return round(
            (background_cutoff - value)
            * 255
            / (background_cutoff - opaque_cutoff)
        )

    mask = ImageChops.multiply(
        luminance.point(mask_value),
        source.getchannel("A"),
    )

    safe_area = Image.new("L", source.size, 0)
    inset = round(source.width * SYMBOL_SAFE_AREA_INSET_RATIO)
    ImageDraw.Draw(safe_area).rectangle(
        (
            inset,
            inset,
            source.width - inset - 1,
            source.height - inset - 1,
        ),
        fill=255,
    )
    return ImageChops.multiply(mask, safe_area)


def make_app_icon() -> None:
    source = square_image(SOURCE_ICON)

    bounds = source.getchannel("A").getbbox()
    if bounds is None:
        raise ValueError("App icon source is fully transparent")

    bounds_area = (bounds[2] - bounds[0]) * (bounds[3] - bounds[1])
    source_area = source.width * source.height
    if bounds_area / source_area >= SOURCE_CROP_MIN_COVERAGE:
        tile = source.crop(bounds)
    else:
        tile = source
    tile = ImageOps.contain(
        tile,
        (APP_ICON_CONTENT_SIZE, APP_ICON_CONTENT_SIZE),
        Image.Resampling.LANCZOS,
    )
    image = Image.new(
        "RGBA",
        (APP_ICON_SIZE, APP_ICON_SIZE),
        (0, 0, 0, 0),
    )
    image.alpha_composite(
        tile,
        ((image.width - tile.width) // 2, (image.height - tile.height) // 2),
    )
    image.save(APP_ICON)


def make_menubar_icon() -> None:
    source = square_image(SOURCE_ICON)
    mask = symbol_mask(source)
    bounds = mask.getbbox()
    if bounds is None:
        raise ValueError("App icon source does not contain a dark symbol")

    mask = mask.crop(bounds)
    graphic = ImageOps.contain(
        mask,
        (MENUBAR_SYMBOL_SIZE, MENUBAR_SYMBOL_SIZE),
        Image.Resampling.LANCZOS,
    )

    image = Image.new(
        "RGBA",
        (MENUBAR_CANVAS_SIZE, MENUBAR_CANVAS_SIZE),
        (0, 0, 0, 0),
    )
    glyph = Image.new("RGBA", graphic.size, (0, 0, 0, 255))
    glyph.putalpha(graphic)
    image.alpha_composite(
        glyph,
        (
            (MENUBAR_CANVAS_SIZE - graphic.width) // 2,
            (MENUBAR_CANVAS_SIZE - graphic.height) // 2,
        ),
    )
    image.save(MENUBAR_ICON)


def make_popclip_icon() -> None:
    source = square_image(SOURCE_ICON)
    mask = symbol_mask(source)
    bounds = mask.getbbox()
    if bounds is None:
        raise ValueError("App icon source does not contain a PopClip symbol")

    symbol = source.crop(bounds)
    grayscale = ImageOps.grayscale(symbol.convert("RGB"))
    symbol = Image.merge(
        "RGBA",
        (
            grayscale,
            grayscale,
            grayscale,
            mask.crop(bounds),
        ),
    )
    symbol = ImageOps.contain(
        symbol,
        (POPCLIP_SYMBOL_SIZE, POPCLIP_SYMBOL_SIZE),
        Image.Resampling.LANCZOS,
    )

    image = Image.new(
        "RGBA",
        (POPCLIP_CANVAS_SIZE, POPCLIP_CANVAS_SIZE),
        (0, 0, 0, 0),
    )
    image.alpha_composite(
        symbol,
        (
            (POPCLIP_CANVAS_SIZE - symbol.width) // 2,
            (POPCLIP_CANVAS_SIZE - symbol.height) // 2,
        ),
    )
    POPCLIP_ICON.parent.mkdir(parents=True, exist_ok=True)
    image.save(POPCLIP_ICON)


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
    try:
        for pixel_size, filename in sizes:
            source.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS).save(
                ICONSET / filename
            )

        try:
            subprocess.run(
                ["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
                check=True,
            )
        except subprocess.CalledProcessError as iconutil_error:
            # macOS 26's iconutil rejects otherwise valid PNG iconsets in some
            # environments. Fall back to the system TIFF converter, which
            # produces a valid ICNS while retaining the same artwork and alpha.
            fallback_sizes = (16, 32, 48, 128, 256, 512, 1024)
            with tempfile.TemporaryDirectory(prefix="kcdeepl-icon-") as temporary_dir:
                tiff_path = Path(temporary_dir) / "AppIcon.tiff"
                frames = [
                    source.resize(
                        (pixel_size, pixel_size), Image.Resampling.LANCZOS
                    ).convert("RGBA")
                    for pixel_size in fallback_sizes
                ]
                frames[0].save(
                    tiff_path,
                    save_all=True,
                    append_images=frames[1:],
                )
                try:
                    subprocess.run(
                        ["tiff2icns", str(tiff_path), str(ICNS)],
                        check=True,
                    )
                except (FileNotFoundError, subprocess.CalledProcessError) as fallback_error:
                    raise RuntimeError(
                        "Unable to create AppIcon.icns with iconutil or tiff2icns"
                    ) from fallback_error
            print(
                "iconutil rejected the iconset; generated AppIcon.icns with tiff2icns"
            )
            if not ICNS.is_file() or ICNS.stat().st_size == 0:
                raise RuntimeError(
                    "tiff2icns did not produce a non-empty AppIcon.icns"
                ) from iconutil_error
    finally:
        shutil.rmtree(ICONSET, ignore_errors=True)


def validate_png(
    path: Path,
    expected_size: tuple[int, int],
    *,
    require_transparent_corners: bool,
) -> None:
    image = square_image(path)
    if image.size != expected_size:
        raise ValueError(
            f"Unexpected icon size for {path}: {image.size}, expected {expected_size}"
        )

    alpha = image.getchannel("A")
    if alpha.getbbox() is None:
        raise ValueError(f"Generated icon is fully transparent: {path}")

    if require_transparent_corners:
        corners = (
            alpha.getpixel((0, 0)),
            alpha.getpixel((image.width - 1, 0)),
            alpha.getpixel((0, image.height - 1)),
            alpha.getpixel((image.width - 1, image.height - 1)),
        )
        if any(corners):
            raise ValueError(f"Generated icon corners are not transparent: {path}")


def validate_outputs() -> None:
    source_size = square_image(SOURCE_ICON).size
    validate_png(
        SOURCE_ICON,
        source_size,
        require_transparent_corners=True,
    )
    validate_png(
        APP_ICON,
        (APP_ICON_SIZE, APP_ICON_SIZE),
        require_transparent_corners=True,
    )
    validate_png(
        MENUBAR_ICON,
        (MENUBAR_CANVAS_SIZE, MENUBAR_CANVAS_SIZE),
        require_transparent_corners=True,
    )
    validate_png(
        POPCLIP_ICON,
        (POPCLIP_CANVAS_SIZE, POPCLIP_CANVAS_SIZE),
        require_transparent_corners=True,
    )
    if not ICNS.is_file() or ICNS.stat().st_size == 0:
        raise ValueError(f"Generated ICNS file is missing or empty: {ICNS}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate KC DeepL application, menu bar, and PopClip icons."
    )
    parser.add_argument(
        "--design",
        type=Path,
        help=(
            "Optional square design image to prepare as AppIconSource.png "
            "before generating the platform icons."
        ),
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    if arguments.design is not None:
        design_path = arguments.design.expanduser().resolve()
        if not design_path.is_file():
            raise FileNotFoundError(f"Missing icon design image: {design_path}")
        prepare_source_icon(design_path)

    if not SOURCE_ICON.exists():
        raise FileNotFoundError(f"Missing source icon image: {SOURCE_ICON}")

    RESOURCES.mkdir(parents=True, exist_ok=True)
    make_app_icon()
    make_menubar_icon()
    make_popclip_icon()
    make_icns()
    validate_outputs()

    for output in (
        SOURCE_ICON,
        APP_ICON,
        MENUBAR_ICON,
        ICNS,
        POPCLIP_ICON,
    ):
        print(output.relative_to(ROOT))


if __name__ == "__main__":
    main()
