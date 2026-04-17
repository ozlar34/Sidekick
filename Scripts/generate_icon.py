#!/usr/bin/env python3
"""Sidekick app icon — cream paper note on an indigo squircle tray.

Treated as a miniature product photograph (per the mac-app-icon skill):
- Backdrop: deep indigo superellipse tray, diagonally lit from upper-left
- Hero: cream paper card, tilted slightly, ~60% of squircle
- Material: paper with gradient + top highlight + bottom form shadow
- Content: abstract heading + body bars (not text glyphs) — reads as
  'formatted note' at large sizes, dissolves gracefully at 16px
- Soft contact shadow grounds the paper on the tray
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
SQUIRCLE_SIZE = 824
SQUIRCLE_MARGIN = (CANVAS - SQUIRCLE_SIZE) // 2  # 100px
SQUIRCLE_N = 5.0  # superellipse exponent — canonical macOS squircle

# Palette
TRAY_TL = (48, 62, 92)          # indigo, upper-left
TRAY_BR = (18, 24, 41)          # deeper indigo, lower-right
PAPER_TOP = (250, 245, 232)     # warm cream
PAPER_BOTTOM = (238, 229, 209)  # slightly darker cream
HEADING_INK = (56, 62, 82)      # dark indigo-gray for heading bars
BODY_INK = (130, 136, 156)      # mid gray-blue for body text bars

PAPER_TILT_DEG = -4.0            # slight leftward tilt (note sliding in)


def squircle_mask(size: int, n: float = SQUIRCLE_N, supersample: int = 4) -> Image.Image:
    """Antialiased superellipse mask (|x/a|^n + |y/b|^n = 1, n≈5 for macOS)."""
    s = size * supersample
    mask = Image.new("L", (s, s), 0)
    px = mask.load()
    half = s / 2.0
    for y in range(s):
        ny = (y - half + 0.5) / half
        ny_n = abs(ny) ** n
        if ny_n >= 1.0:
            continue
        x_frac = (1.0 - ny_n) ** (1.0 / n)
        x_extent = x_frac * half
        x0 = max(0, int(round(half - x_extent)))
        x1 = min(s, int(round(half + x_extent)))
        for x in range(x0, x1):
            px[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def diagonal_gradient(size: tuple[int, int], top_left, bottom_right) -> Image.Image:
    """RGB gradient along the image diagonal (top-left → bottom-right)."""
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    norm = math.sqrt(w * w + h * h)
    for y in range(h):
        for x in range(w):
            t = math.sqrt(x * x + y * y) / norm
            r = int(top_left[0] + (bottom_right[0] - top_left[0]) * t)
            g = int(top_left[1] + (bottom_right[1] - top_left[1]) * t)
            b = int(top_left[2] + (bottom_right[2] - top_left[2]) * t)
            px[x, y] = (r, g, b)
    return img


def vertical_gradient(size: tuple[int, int], top, bottom) -> Image.Image:
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def radial_falloff(size: int, center, radius: float, color_rgba) -> Image.Image:
    """Soft radial falloff layer. Used for highlights + inner shadows."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    cx, cy = center
    r_max, g_max, b_max, a_max = color_rgba
    for y in range(size):
        for x in range(size):
            dx = x - cx
            dy = y - cy
            d = math.sqrt(dx * dx + dy * dy)
            if d >= radius:
                continue
            t = 1.0 - d / radius
            t *= t  # ease-in
            a = int(a_max * t)
            if a > 0:
                px[x, y] = (r_max, g_max, b_max, a)
    return img


def build_tray() -> Image.Image:
    """Deep indigo squircle with diagonal gradient + overhead-light treatment."""
    size = SQUIRCLE_SIZE
    base = diagonal_gradient((size, size), TRAY_TL, TRAY_BR).convert("RGBA")

    # Specular arc along top inside edge (tray surface catching light).
    top_arc = radial_falloff(size, (size / 2, -size * 0.20),
                             size * 0.90, (255, 255, 255, 80))
    base = Image.alpha_composite(base, top_arc)

    # Upper-left soft accent — reinforces the 10-o'clock light direction.
    accent = radial_falloff(size, (size * 0.26, size * 0.14),
                            size * 0.48, (255, 255, 255, 48))
    base = Image.alpha_composite(base, accent)

    # Inner bottom darkening — subtle containment / ambient occlusion.
    bottom = radial_falloff(size, (size / 2, size * 1.18),
                            size * 0.85, (0, 0, 0, 95))
    base = Image.alpha_composite(base, bottom)

    mask = squircle_mask(size)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    return out


def draw_paper_flat(pw: int, ph: int) -> Image.Image:
    """Unrotated cream paper card with baked material + markdown content."""
    corner = int(pw * 0.045)
    paper = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))

    # Rounded-rect shape mask
    shape_mask = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(shape_mask).rounded_rectangle((0, 0, pw, ph), radius=corner, fill=255)

    # Body: cream vertical gradient clipped to the rounded-rect
    body = vertical_gradient((pw, ph), PAPER_TOP, PAPER_BOTTOM).convert("RGBA")
    paper.paste(body, (0, 0), shape_mask)

    # Top highlight — soft white gradient fading out after ~25% of height
    hl = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    hld = ImageDraw.Draw(hl)
    hld.rounded_rectangle((0, 0, pw, int(ph * 0.22)), radius=corner,
                          fill=(255, 255, 255, 70))
    hl = hl.filter(ImageFilter.GaussianBlur(radius=14))
    hl_clip = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    hl_clip.paste(hl, (0, 0), shape_mask)
    paper = Image.alpha_composite(paper, hl_clip)

    # Bottom form shadow — paper's underside slightly darker under overhead light
    fs = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    ImageDraw.Draw(fs).rounded_rectangle(
        (0, int(ph * 0.78), pw, ph), radius=corner, fill=(0, 0, 0, 55))
    fs = fs.filter(ImageFilter.GaussianBlur(radius=22))
    fs_clip = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    fs_clip.paste(fs, (0, 0), shape_mask)
    paper = Image.alpha_composite(paper, fs_clip)

    # Markdown-abstract content: one heading bar, one subheading, then body lines.
    ink = ImageDraw.Draw(paper)
    pad_x = int(pw * 0.13)

    # Heading (bold, wide, dark)
    h_y = int(ph * 0.22)
    h_h = max(8, int(ph * 0.042))
    ink.rounded_rectangle(
        (pad_x, h_y, pw - pad_x - int(pw * 0.10), h_y + h_h),
        radius=h_h // 2, fill=HEADING_INK)

    # Sub-heading (shorter, thinner)
    sh_y = h_y + h_h + int(ph * 0.04)
    sh_h = max(5, int(ph * 0.028))
    ink.rounded_rectangle(
        (pad_x, sh_y, pw - pad_x - int(pw * 0.33), sh_y + sh_h),
        radius=sh_h // 2, fill=HEADING_INK)

    # Body lines — thinner, lighter, varied widths
    body_h = max(4, int(ph * 0.020))
    body_r = body_h // 2
    body_gap = int(ph * 0.072)
    body_y = int(ph * 0.48)
    widths = [0.80, 0.90, 0.72, 0.84, 0.58]
    usable = pw - 2 * pad_x
    for i, frac in enumerate(widths):
        y = body_y + i * body_gap
        ink.rounded_rectangle(
            (pad_x, y, pad_x + int(usable * frac), y + body_h),
            radius=body_r, fill=BODY_INK)

    return paper


def build_paper_and_shadow() -> tuple[Image.Image, Image.Image]:
    """
    Build the tilted paper layer + a soft blurred contact shadow beneath it.
    Both returned canvases are SQUIRCLE_SIZE × SQUIRCLE_SIZE (unclipped).
    """
    size = SQUIRCLE_SIZE
    pw = int(size * 0.60)           # ~494
    ph = int(size * 0.78)           # ~643

    paper_flat = draw_paper_flat(pw, ph)

    # Rotate (expand to avoid clipping the corners)
    paper_rot = paper_flat.rotate(PAPER_TILT_DEG, resample=Image.BICUBIC, expand=True)

    # Contact shadow — paper silhouette, blurred, offset down-right
    corner = int(pw * 0.045)
    sil = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    ImageDraw.Draw(sil).rounded_rectangle(
        (0, 0, pw, ph), radius=corner, fill=(0, 0, 0, 205))
    sil_rot = sil.rotate(PAPER_TILT_DEG, resample=Image.BICUBIC, expand=True)
    shadow = sil_rot.filter(ImageFilter.GaussianBlur(radius=46))

    # Place on squircle-sized canvas, centered, slightly above optical center
    optical_up = int(size * 0.015)  # 3% of canvas ≈ optical center shift
    rw, rh = paper_rot.size
    px = (size - rw) // 2
    py = (size - rh) // 2 - optical_up

    paper_canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Shadow nudged slightly down + right (overhead-front-left light)
    shadow_canvas.paste(shadow, (px + 14, py + 26), shadow)
    paper_canvas.paste(paper_rot, (px, py), paper_rot)

    return paper_canvas, shadow_canvas


def compose_icon() -> Image.Image:
    """Full 1024×1024 compose: tray → contact shadow → paper, clipped to squircle."""
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    tray = build_tray()
    paper, shadow = build_paper_and_shadow()

    composite = Image.alpha_composite(tray, shadow)
    composite = Image.alpha_composite(composite, paper)

    # Re-clip to squircle in case rotation pushed anything out
    mask = squircle_mask(SQUIRCLE_SIZE)
    clipped = Image.new("RGBA", (SQUIRCLE_SIZE, SQUIRCLE_SIZE), (0, 0, 0, 0))
    clipped.paste(composite, (0, 0), mask)

    canvas.paste(clipped, (SQUIRCLE_MARGIN, SQUIRCLE_MARGIN), clipped)
    return canvas


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    iconset = repo_root / "Resources" / "AppIcon.iconset"

    master = compose_icon()
    master.save(iconset / "icon_512x512@2x.png", format="PNG")
    print(f"wrote {iconset / 'icon_512x512@2x.png'} (1024×1024 master)")

    # All other iconset sizes come from the master.
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
    ]
    for px, name in sizes:
        resized = master.resize((px, px), Image.LANCZOS)
        resized.save(iconset / name, format="PNG")
        print(f"wrote {name} ({px}×{px})")


if __name__ == "__main__":
    main()
