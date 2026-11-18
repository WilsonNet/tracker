#!/usr/bin/env python3
"""Bake the two anti-aliased UI font atlases embedded by the native renderer.

The software canvas draws glyphs by blending 8-bit coverage values, exactly the
way ImGui/fontstash consume an Alpha8 atlas -- but the rasterisation happens
here, at development time, so the Odin build has no FreeType, stb_truetype or
font-file dependency at runtime. The generated file is committed and is the
only input to `canvas_text`.

Two atlases are baked from the same monospace family:

  small  8 x 15 cells, font size 12.5 px, baseline row 12   (scale 1 text)
  large 16 x 30 cells, font size 25 px,   baseline row 24   (scale 2 headings)

The cells are exact 2x companions, so `canvas_text(..., scale = 2)` uses the
large atlas instead of magnifying blocky pixels. Larger scales nearest-sample
the large atlas.

Run from odin/:  python3 scripts/gen_font.py
Requires Pillow. Pillow's TrueType rasteriser (FreeType) is used only while
generating; the runtime has no font stack.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src", "ui", "font_data.odin")

FIRST, LAST = 32, 126
SMALL_W, SMALL_H, SMALL_SIZE, SMALL_BASELINE = 8, 15, 12.5, 12
LARGE_W, LARGE_H, LARGE_SIZE, LARGE_BASELINE = 16, 30, 25.0, 24

NOTO = "/usr/share/fonts/noto/NotoSansMono-Regular.ttf"
NOTO_MEDIUM = "/usr/share/fonts/noto/NotoSansMono-Medium.ttf"


def fc_match(family: str) -> str | None:
    """Return the file fontconfig selects for `family`, if it is that family."""
    fc = shutil.which("fc-match")
    if not fc:
        return None
    try:
        path = subprocess.check_output(
            [fc, "-f", "%{file}", family], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    if not path or not os.path.exists(path):
        return None
    # fc-match always returns a best match; only accept an actual match.
    needle = family.replace(" ", "").lower()
    if needle not in os.path.basename(path).lower():
        return None
    return path


def resolve_fonts(explicit: str | None) -> tuple[str, str]:
    if explicit:
        return explicit, explicit
    # DESIGN.md names JetBrains Mono first; use it when the machine has it.
    jetbrains = fc_match("JetBrains Mono")
    if jetbrains:
        return jetbrains, jetbrains
    # Noto Sans Mono has no large optical-size cut; Medium at 12.5 px keeps
    # small labels legible on the near-black surface, Regular at 25 px keeps
    # headings and the timecode from looking heavy.
    small = NOTO_MEDIUM if os.path.exists(NOTO_MEDIUM) else NOTO
    return small, NOTO


def bake(font_path: str, size: float, w: int, h: int, baseline: int) -> list[list[list[int]]]:
    """Rasterise ASCII 32..126 into fixed cells with a shared baseline.

    `baseline` is the row of the baseline inside the cell. Pillow's anchor "ls"
    puts the pen on the left baseline, so all glyphs share metrics and
    descenders (g j p q y) land below it consistently.
    """
    font = ImageFont.truetype(font_path, size)
    glyphs: list[list[list[int]]] = []
    for code in range(FIRST, LAST + 1):
        img = Image.new("L", (w, h), 0)
        d = ImageDraw.Draw(img)
        d.text((0, baseline), chr(code), font=font, fill=255, anchor="ls")
        # Fail loudly if a glyph does not fit: clipped ink is the bug this
        # file exists to fix.
        bbox = img.getbbox()
        if bbox is not None:
            x0, y0, x1, y1 = bbox
            if x0 < 0 or y0 < 0 or x1 > w or y1 > h:
                raise SystemExit(
                    f"glyph {chr(code)!r} clipped: bbox={bbox} cell={w}x{h} baseline={baseline}"
                )
        rows = []
        for y in range(h):
            rows.append([img.getpixel((x, y)) for x in range(w)])
        glyphs.append(rows)
    return glyphs


def pack_row(values: list[int]) -> int:
    v = 0
    for a in values:
        v = (v << 8) | a
    return v


def emit(font_path: str | None, out_path: str, small_font_override: str | None = None,
         large_font_override: str | None = None) -> None:
    default_small, default_large = resolve_fonts(font_path)
    small_font = small_font_override or default_small
    large_font = large_font_override or default_large
    small = bake(small_font, SMALL_SIZE, SMALL_W, SMALL_H, SMALL_BASELINE)
    large = bake(large_font, LARGE_SIZE, LARGE_W, LARGE_H, LARGE_BASELINE)

    aa_small = sum(1 for g in small for row in g for a in row if 0 < a < 255)
    aa_large = sum(1 for g in large for row in g for a in row if 0 < a < 255)
    if aa_small == 0 or aa_large == 0:
        raise SystemExit("rasteriser produced no intermediate alpha; check Pillow build")

    name = os.path.basename(small_font)
    if small_font != large_font:
        name = f"{name} + {os.path.basename(large_font)}"
    with open(out_path, "w") as f:
        f.write("// Generated by scripts/gen_font.py -- do not edit by hand.\n")
        f.write(f"// Source: {name}; Pillow/FreeType anti-aliased coverage, ASCII 32..126.\n")
        f.write("//\n")
        f.write(f"// Small atlas: {SMALL_W}x{SMALL_H} cells at {SMALL_SIZE}px, baseline row {SMALL_BASELINE}.\n")
        f.write(f"// Large atlas: {LARGE_W}x{LARGE_H} cells at {LARGE_SIZE}px, baseline row {LARGE_BASELINE}.\n")
        f.write("// Each row packs one 8-bit alpha value per pixel, MSB = leftmost pixel.\n")
        f.write("// 0 = transparent, 255 = full ink; values in between are edge coverage.\n\n")
        f.write("package ui\n\n")
        f.write(f"FONT_W :: {SMALL_W}\n")
        f.write(f"FONT_H :: {SMALL_H}\n")
        f.write(f"FONT_FIRST :: {FIRST}\n")
        f.write(f"FONT_LAST :: {LAST}\n\n")
        f.write("// Metrics of the baked cells. canvas_text treats y as the cell top.\n")
        f.write(f"FONT_SMALL_BASELINE :: {SMALL_BASELINE}\n")
        f.write(f"FONT_LARGE_W :: {LARGE_W}\n")
        f.write(f"FONT_LARGE_H :: {LARGE_H}\n")
        f.write(f"FONT_LARGE_BASELINE :: {LARGE_BASELINE}\n\n")

        f.write(f"FONT_SMALL_ALPHA := [{len(small)}][{SMALL_H}]u64{{\n")
        for i, rows in enumerate(small):
            ch = chr(FIRST + i)
            label = {" ": "space", "\\": "backslash", '"': "quote"}.get(ch, ch)
            packed = ", ".join("0x%016x" % pack_row(row) for row in rows)
            f.write(f"\t{{ {packed} }}, // {label}\n")
        f.write("}\n\n")

        f.write(f"FONT_LARGE_ALPHA := [{len(large)}][{LARGE_H}][2]u64{{\n")
        for i, rows in enumerate(large):
            ch = chr(FIRST + i)
            label = {" ": "space", "\\": "backslash", '"': "quote"}.get(ch, ch)
            f.write(f"\t// {label}\n")
            f.write("\t{\n")
            for row in rows:
                f.write("\t\t{ 0x%016x, 0x%016x },\n" % (pack_row(row[:8]), pack_row(row[8:])))
            f.write("\t},\n")
        f.write("}\n")

    size = os.path.getsize(out_path)
    print(
        f"wrote {os.path.relpath(out_path)}: {len(small)} glyphs "
        f"({SMALL_W}x{SMALL_H} @ {SMALL_SIZE}px, {LARGE_W}x{LARGE_H} @ {LARGE_SIZE}px), "
        f"{aa_small + aa_large} anti-aliased pixels, {size / 1024:.0f} KiB"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--font", help="TTF path for both sizes (default: JetBrains Mono if installed, else Noto Sans Mono Medium/Regular)")
    ap.add_argument("--small-font", help="TTF path override for the small atlas")
    ap.add_argument("--large-font", help="TTF path override for the large atlas")
    ap.add_argument("--out", default=OUT, help="generated Odin file")
    args = ap.parse_args()
    emit(args.font, args.out, args.small_font, args.large_font)


if __name__ == "__main__":
    main()
