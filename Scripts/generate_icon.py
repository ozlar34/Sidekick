#!/usr/bin/env python3
"""Sidekick app icon — cream paper card sliding in from the right.

Treated as a miniature product photograph (per the mac-app-icon skill):
- Backdrop: warm-cream superellipse tray, diagonally lit from upper-left
- Hero: cream paper card peeking in from the right edge of the tray, with
  a muted-purple "slide-in" strip along its left edge — mirrors the app's
  actual slide-in-from-right panel mechanic
- Material: paper with gradient + top highlight + bottom form shadow
- Content: subtle graphite ruled lines — read as 'paper' at any size,
  dissolve gracefully at 16px into a clean silhouette

Output:
  - Resources/AppIcon.iconset/  (10 PNG sizes, Apple filename convention)
  - Resources/AppIcon.icns      (compiled via iconutil)
  - Resources/StatusBarIconTemplate.png      (18x18 template, monochrome)
  - Resources/StatusBarIconTemplate@2x.png   (36x36 template, monochrome)
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
MARGIN = 100
INNER = CANVAS - 2 * MARGIN  # 824
SQUIRCLE_N = 5.0

# Palette — warm cream + graphite + muted purple
CREAM_LIGHT = (246, 232, 206)
CREAM_DEEP = (212, 190, 160)
PAPER_TOP = (254, 246, 227)
PAPER_BOT = (236, 222, 192)
PURPLE = (120, 92, 156)
PURPLE_DARK = (92, 70, 128)
GRAPHITE = (58, 48, 80)
SHADOW = (56, 40, 72)

ICONSET_SIZES = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]


def squircle_mask(size: int, n: float = SQUIRCLE_N, supersample: int = 4) -> Image.Image:
    """Superellipse alpha mask (|x/a|^n + |y/b|^n = 1, n≈5). White inside, black outside."""
    s = size * supersample
    mask = Image.new("L", (s, s), 0)
    px = mask.load()
    half = s / 2.0
    for y in range(s):
        ny = (y - half + 0.5) / half
        ny_abs_n = abs(ny) ** n
        if ny_abs_n >= 1.0:
            continue
        x_frac = (1.0 - ny_abs_n) ** (1.0 / n)
        x_pixels = x_frac * half
        x0 = int(round(half - x_pixels))
        x1 = int(round(half + x_pixels))
        if x1 <= x0:
            continue
        for x in range(max(0, x0), min(s, x1)):
            px[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def make_diagonal_gradient(size: int, c0: tuple[int, int, int], c1: tuple[int, int, int]) -> Image.Image:
    """Top-left c0 → bottom-right c1."""
    grad = Image.new("RGB", (size, size))
    px = grad.load()
    max_d = (size - 1) * 2
    for y in range(size):
        for x in range(size):
            t = (x + y) / max_d
            r = int(c0[0] + (c1[0] - c0[0]) * t)
            g = int(c0[1] + (c1[1] - c0[1]) * t)
            b = int(c0[2] + (c1[2] - c0[2]) * t)
            px[x, y] = (r, g, b)
    return grad


def make_vertical_gradient(w: int, h: int, c_top: tuple[int, int, int], c_bot: tuple[int, int, int]) -> Image.Image:
    grad = Image.new("RGB", (w, h))
    px = grad.load()
    for y in range(h):
        t = y / (h - 1)
        r = int(c_top[0] + (c_bot[0] - c_top[0]) * t)
        g = int(c_top[1] + (c_bot[1] - c_top[1]) * t)
        b = int(c_top[2] + (c_bot[2] - c_top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return grad


def rounded_rect_mask(w: int, h: int, radius: int, supersample: int = 3) -> Image.Image:
    s = supersample
    m = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [(0, 0), (w * s - 1, h * s - 1)], radius=radius * s, fill=255
    )
    return m.resize((w, h), Image.LANCZOS)


def compose_card() -> Image.Image:
    """Build the paper-card hero as a standalone RGBA image."""
    card_w, card_h = 680, 660
    radius = 48
    strip_w = 58

    # Opaque base with subtle top→bottom paper gradient.
    card_rgb = make_vertical_gradient(card_w, card_h, PAPER_TOP, PAPER_BOT)

    # Purple "slide-in" strip with a darker seam on its right edge.
    d = ImageDraw.Draw(card_rgb)
    d.rectangle([(0, 0), (strip_w, card_h)], fill=PURPLE)
    d.rectangle([(strip_w - 3, 0), (strip_w, card_h)], fill=PURPLE_DARK)

    card = card_rgb.convert("RGBA")

    # Graphite ruled lines — thin, low alpha, dissolve gracefully at small sizes.
    rules = Image.new("RGBA", (card_w, card_h), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rules)
    line_x0 = strip_w + 70
    line_x1 = card_w - 70
    for ly in (200, 280, 360, 440, 520):
        rd.rectangle([(line_x0, ly), (line_x1, ly + 3)], fill=GRAPHITE + (70,))
    card.alpha_composite(rules)

    # Top highlight (overhead-front light falling on paper).
    hi = Image.new("RGBA", (card_w, card_h), (0, 0, 0, 0))
    ImageDraw.Draw(hi).rectangle([(0, 0), (card_w, 120)], fill=(255, 255, 255, 55))
    hi = hi.filter(ImageFilter.GaussianBlur(radius=36))
    card.alpha_composite(hi)

    # Lower-right self-shadow on paper.
    dk = Image.new("RGBA", (card_w, card_h), (0, 0, 0, 0))
    ImageDraw.Draw(dk).ellipse(
        [(card_w - 280, card_h - 240), (card_w + 80, card_h + 80)],
        fill=(60, 40, 30, 60),
    )
    dk = dk.filter(ImageFilter.GaussianBlur(radius=40))
    card.alpha_composite(dk)

    # Rounded-rectangle alpha mask at the very end.
    card.putalpha(rounded_rect_mask(card_w, card_h, radius))
    return card


def render_master() -> Image.Image:
    """Full 1024×1024 RGBA master."""
    # Tray
    tray_grad = make_diagonal_gradient(INNER, CREAM_LIGHT, CREAM_DEEP).convert("RGBA")
    sq_mask = squircle_mask(INNER)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(tray_grad, (MARGIN, MARGIN), sq_mask)

    sq_full = Image.new("L", (CANVAS, CANVAS), 0)
    sq_full.paste(sq_mask, (MARGIN, MARGIN))

    # Top-edge specular on the tray.
    spec = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(spec).ellipse(
        [(MARGIN - 60, MARGIN + 40), (CANVAS - MARGIN + 60, MARGIN + 190)],
        fill=(255, 255, 255, 90),
    )
    spec = spec.filter(ImageFilter.GaussianBlur(radius=36))
    spec_clipped = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    spec_clipped.paste(spec, (0, 0), sq_full)
    canvas.alpha_composite(spec_clipped)

    # Card
    card = compose_card()
    card_w, card_h = card.size
    card_x = CANVAS - card_w - 30
    card_y = (CANVAS - card_h) // 2 + 10

    # Contact shadow (blurred, clipped to squircle).
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    s_block = Image.new("RGBA", (card_w, card_h), SHADOW + (180,))
    s_block.putalpha(rounded_rect_mask(card_w, card_h, 48))
    shadow.alpha_composite(s_block, (card_x - 12, card_y + 30))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=32))
    shadow_clipped = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_clipped.paste(shadow, (0, 0), sq_full)
    canvas.alpha_composite(shadow_clipped)

    # Card itself, clipped to squircle (right overhang ends at tray curve).
    card_layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    card_layer.alpha_composite(card, (card_x, card_y))
    card_clipped = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    card_clipped.paste(card_layer, (0, 0), sq_full)
    canvas.alpha_composite(card_clipped)
    return canvas


def render_status_bar_template(size: int) -> Image.Image:
    """Monochrome template for the menu bar. System auto-tints via isTemplate.

    Composition: an outlined rounded rectangle (the card silhouette) with a
    filled vertical strip along its left edge — the "slide-in" indicator.
    At 18pt the outline + strip reads as "card with emphasized leading edge,"
    directly mirroring the app icon's hero without detail that would smear.
    """
    # Render at 8x then downsample for crisp edges.
    s = size * 8
    img = Image.new("L", (s, s), 0)  # L mode: grayscale, we composite to RGBA at end
    draw = ImageDraw.Draw(img)

    card_left = int(s * 0.18)
    card_right = int(s * 0.92)
    card_top = int(s * 0.14)
    card_bot = int(s * 0.86)
    radius = int(s * 0.14)

    # Card outline — stroked rounded rectangle.
    stroke_w = max(2, int(s * 0.035))
    draw.rounded_rectangle(
        [(card_left, card_top), (card_right, card_bot)],
        radius=radius,
        outline=255,
        width=stroke_w,
    )

    # Filled "slide-in" strip on the leading edge — fully opaque, clearly distinct
    # from the outlined body.
    strip_w = int(s * 0.16)
    # Clip strip to rounded-rect body so it follows the card's left radius.
    body_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(body_mask).rounded_rectangle(
        [(card_left, card_top), (card_right, card_bot)], radius=radius, fill=255
    )
    strip = Image.new("L", (s, s), 0)
    ImageDraw.Draw(strip).rectangle(
        [(card_left, card_top), (card_left + strip_w, card_bot)], fill=255
    )
    clipped_strip = Image.new("L", (s, s), 0)
    strip_arr = strip.load()
    mask_arr = body_mask.load()
    cs_arr = clipped_strip.load()
    for y in range(s):
        for x in range(s):
            if strip_arr[x, y] and mask_arr[x, y]:
                cs_arr[x, y] = 255
    # Merge strip into the outline image.
    img_arr = img.load()
    for y in range(s):
        for x in range(s):
            if cs_arr[x, y] > 0:
                img_arr[x, y] = 255

    # Downsample first (smoother edges), then convert to RGBA template.
    small = img.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out_arr = out.load()
    small_arr = small.load()
    for y in range(size):
        for x in range(size):
            v = small_arr[x, y]
            if v > 0:
                out_arr[x, y] = (0, 0, 0, v)
    return out


def build_iconset(master: Image.Image, iconset_dir: Path) -> None:
    iconset_dir.mkdir(parents=True, exist_ok=True)
    for base, scale, name in ICONSET_SIZES:
        px = base * scale
        if px == master.size[0]:
            master.save(iconset_dir / name, format="PNG")
        else:
            master.resize((px, px), Image.LANCZOS).save(iconset_dir / name, format="PNG")


def compile_icns(iconset_dir: Path, output: Path) -> None:
    res = subprocess.run(
        ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(output)],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"iconutil failed: {res.stderr or res.stdout}")


def main() -> int:
    project_root = Path(__file__).resolve().parents[1]
    resources = project_root / "Resources"
    resources.mkdir(parents=True, exist_ok=True)

    master = render_master()
    master_path = resources / "AppIcon_master.png"
    master.save(master_path, format="PNG")
    print(f"wrote master: {master_path}")

    iconset_dir = resources / "AppIcon.iconset"
    # Clean old iconset to avoid stale PNGs sticking around.
    if iconset_dir.exists():
        for p in iconset_dir.glob("*.png"):
            p.unlink()
    build_iconset(master, iconset_dir)
    print(f"wrote iconset: {iconset_dir}")

    icns = resources / "AppIcon.icns"
    compile_icns(iconset_dir, icns)
    print(f"wrote icns:    {icns}")

    sb1 = render_status_bar_template(18)
    sb2 = render_status_bar_template(36)
    (resources / "StatusBarIconTemplate.png").write_bytes(b"")  # reset to avoid stale meta
    sb1.save(resources / "StatusBarIconTemplate.png", format="PNG")
    sb2.save(resources / "StatusBarIconTemplate@2x.png", format="PNG")
    print(f"wrote status-bar template: {resources / 'StatusBarIconTemplate.png'}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
