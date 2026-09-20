#!/usr/bin/env python3
"""
Compose connected App Store marketing screenshots for Sideline.

Same carousel language as Hamptons Burgers / Doodlr, restyled to Sideline’s
mist clipboard + lime accent system.
"""

from __future__ import annotations

import math
import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

CANVAS_W = 1284
CANVAS_H = 2778

# BrandTheme light mode
MIST = (244, 245, 243)          # F4F5F3
MIST_TOP = (238, 241, 244)      # EEF1F4
INK = (26, 28, 26)              # 1A1C1A
INK_SOFT = (55, 60, 55)
LIME = (184, 240, 0)            # B8F000
LIME_SOFT = (210, 245, 90)
MUTED = (92, 99, 92)            # 5C635C
WASH = (220, 228, 220)
WHITE = (255, 255, 255)


@dataclass(frozen=True)
class Slide:
    source: str
    output: str
    index: int
    total: int
    eyebrow: str
    headline: str
    support: str


SLIDES = [
    Slide(
        source="01-team.png",
        output="01-your-desk.png",
        index=0,
        total=5,
        eyebrow="SIDELINE",
        headline="Your desk.",
        support="Franchise home — starters, salary,\nand the matchup that matters.",
    ),
    Slide(
        source="02-league.png",
        output="02-the-board.png",
        index=1,
        total=5,
        eyebrow="LEAGUE",
        headline="The board.",
        support="Standings, scoreboard, and moves —\nwithout leaving the app.",
    ),
    Slide(
        source="03-agents.png",
        output="03-on-tap.png",
        index=2,
        total=5,
        eyebrow="AGENTS",
        headline="On tap.",
        support="Lineup, waiver, and trade desks\nrun only when you ask.",
    ),
    Slide(
        source="04-approvals.png",
        output="04-you-approve.png",
        index=3,
        total=5,
        eyebrow="APPROVALS",
        headline="You approve.",
        support="Agents propose. Nothing writes\nto MFL until you say so.",
    ),
    Slide(
        source="05-settings.png",
        output="05-your-model.png",
        index=4,
        total=5,
        eyebrow="SETTINGS",
        headline="Your model.",
        support="Bring OpenAI, Anthropic, Google,\nor OpenRouter — keys stay on device.",
    ),
]


def load_fonts() -> dict[str, ImageFont.FreeTypeFont]:
    # Condensed display + clean sans (matches app vibe)
    compressed = "/System/Library/Fonts/Supplemental/Arial Narrow.ttf"
    if not Path(compressed).exists():
        compressed = "/System/Library/Fonts/Avenir Next.ttc"
        return {
            "headline": ImageFont.truetype(compressed, size=118, index=2),
            "eyebrow": ImageFont.truetype(compressed, size=28, index=2),
            "support": ImageFont.truetype(compressed, size=36, index=5),
            "index": ImageFont.truetype(compressed, size=24, index=7),
        }
    sf = "/System/Library/Fonts/SFNS.ttf"
    if not Path(sf).exists():
        sf = "/System/Library/Fonts/Helvetica.ttc"
    return {
        "headline": ImageFont.truetype(compressed, 118),
        "eyebrow": ImageFont.truetype(sf, 28),
        "support": ImageFont.truetype(sf, 36),
        "index": ImageFont.truetype(sf, 24),
    }


def draw_connected_background(index: int, total: int) -> Image.Image:
    img = Image.new("RGBA", (CANVAS_W, CANVAS_H), MIST + (255,))
    overlay = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Soft mist wash drifts across the series
    wash_cx = int((-0.1 + (index / max(total - 1, 1)) * 1.2) * CANVAS_W)
    wash_cy = int(CANVAS_H * 0.70)
    for radius, alpha in ((980, 40), (720, 28), (460, 18)):
        draw.ellipse(
            [wash_cx - radius, wash_cy - radius, wash_cx + radius, wash_cy + radius],
            fill=MIST_TOP + (alpha,),
        )

    # Lime bloom travels the other way
    lime_cx = int((1.1 - (index / max(total - 1, 1)) * 1.2) * CANVAS_W)
    lime_cy = int(CANVAS_H * 0.82)
    for radius, alpha in ((620, 28), (380, 18)):
        draw.ellipse(
            [lime_cx - radius, lime_cy - radius, lime_cx + radius, lime_cy + radius],
            fill=LIME + (alpha,),
        )

    # Continuous lime ribbon
    ribbon = Image.new("RGBA", (CANVAS_W * 3, CANVAS_H), (0, 0, 0, 0))
    rdraw = ImageDraw.Draw(ribbon)
    y0 = int(CANVAS_H * 0.18)
    amplitude = 42
    thickness = 10
    points_top = []
    points_bot = []
    for x in range(0, CANVAS_W * 3, 8):
        y = y0 + int(math.sin(x / 220.0) * amplitude)
        points_top.append((x, y - thickness // 2))
        points_bot.append((x, y + thickness // 2))
    rdraw.polygon(points_top + list(reversed(points_bot)), fill=LIME + (220,))
    points_top2 = [(x, y + 28) for x, y in points_top]
    points_bot2 = [(x, y + 28) for x, y in points_bot]
    rdraw.polygon(points_top2 + list(reversed(points_bot2)), fill=LIME_SOFT + (55,))

    shift = int((index / max(total - 1, 1)) * CANVAS_W)
    cropped = ribbon.crop((shift, 0, shift + CANVAS_W, CANVAS_H))
    overlay = Image.alpha_composite(overlay, cropped)

    rule_y = int(CANVAS_H * 0.235)
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle(
        [96, rule_y, CANVAS_W - 96, rule_y + 3],
        radius=2,
        fill=INK + (35,),
    )
    return Image.alpha_composite(img, overlay)


def rounded_device_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255
    )
    return mask


def frame_phone(screenshot: Image.Image) -> Image.Image:
    bezel = 18
    radius = 92
    inner_radius = 78
    screen = screenshot.convert("RGBA")
    phone_w = screen.width + bezel * 2
    phone_h = screen.height + bezel * 2

    phone = Image.new("RGBA", (phone_w, phone_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(phone)
    draw.rounded_rectangle([0, 0, phone_w - 1, phone_h - 1], radius=radius, fill=INK + (255,))
    inset = 5
    draw.rounded_rectangle(
        [inset, inset, phone_w - 1 - inset, phone_h - 1 - inset],
        radius=radius - 4,
        outline=LIME + (255,),
        width=3,
    )
    lip = 10
    draw.rounded_rectangle(
        [lip, lip, phone_w - 1 - lip, phone_h - 1 - lip],
        radius=radius - 8,
        fill=MIST + (255,),
    )
    screen_mask = rounded_device_mask(screen.size, inner_radius)
    phone.paste(screen, (bezel, bezel), screen_mask)
    return phone


def drop_shadow(device: Image.Image, blur: int = 42, offset: tuple[int, int] = (0, 28)) -> Image.Image:
    alpha = device.split()[-1]
    shadow_layer = Image.new("RGBA", device.size, INK + (70,))
    shadow_layer.putalpha(alpha.point(lambda a: int(a * 0.5)))
    shadow = shadow_layer.filter(ImageFilter.GaussianBlur(blur))
    canvas = Image.new(
        "RGBA",
        (device.width + abs(offset[0]) + blur * 2, device.height + abs(offset[1]) + blur * 2),
        (0, 0, 0, 0),
    )
    ox = blur + max(offset[0], 0)
    oy = blur + max(offset[1], 0)
    canvas.paste(shadow, (ox + offset[0], oy + offset[1]), shadow)
    canvas.paste(device, (ox, oy), device)
    return canvas


def fit_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: int,
) -> ImageFont.FreeTypeFont:
    size = font.size
    path = font.path
    index = getattr(font, "index", 0) or 0
    while size > 48:
        try:
            candidate = ImageFont.truetype(path, size=size, index=index)
        except TypeError:
            candidate = ImageFont.truetype(path, size=size)
        bbox = draw.textbbox((0, 0), text, font=candidate)
        if bbox[2] - bbox[0] <= max_width:
            return candidate
        size -= 4
    try:
        return ImageFont.truetype(path, size=size, index=index)
    except TypeError:
        return ImageFont.truetype(path, size=size)


def draw_progress_dots(draw: ImageDraw.ImageDraw, index: int, total: int, y: int) -> None:
    spacing = 28
    radius = 7
    width = (total - 1) * spacing
    start_x = (CANVAS_W - width) // 2
    for i in range(total):
        x = start_x + i * spacing
        if i == index:
            draw.ellipse(
                [x - radius - 2, y - radius - 2, x + radius + 2, y + radius + 2],
                fill=LIME + (255,),
            )
            draw.ellipse(
                [x - radius + 1, y - radius + 1, x + radius - 1, y + radius - 1],
                fill=INK + (255,),
            )
        else:
            draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=INK + (50,))


def compose_slide(
    raw_dir: Path, out_dir: Path, fonts: dict[str, ImageFont.FreeTypeFont], slide: Slide
) -> Path:
    bg = draw_connected_background(slide.index, slide.total)
    draw = ImageDraw.Draw(bg)

    eyebrow_y = 118
    draw.text((96, eyebrow_y), slide.eyebrow, font=fonts["eyebrow"], fill=MUTED + (255,))
    index_label = f"{slide.index + 1:02d} / {slide.total:02d}"
    index_bbox = draw.textbbox((0, 0), index_label, font=fonts["index"])
    draw.text(
        (CANVAS_W - 96 - (index_bbox[2] - index_bbox[0]), eyebrow_y + 4),
        index_label,
        font=fonts["index"],
        fill=MUTED + (255,),
    )

    headline_font = fit_text(draw, slide.headline, fonts["headline"], CANVAS_W - 192)
    draw.text((96, 178), slide.headline, font=headline_font, fill=INK + (255,))

    support_y = 330
    for i, line in enumerate(slide.support.split("\n")):
        draw.text((96, support_y + i * 46), line, font=fonts["support"], fill=INK_SOFT + (255,))

    shot = Image.open(raw_dir / slide.source).convert("RGBA")
    target_phone_h = int(CANVAS_H * 0.62)
    scale = target_phone_h / shot.height
    scaled = shot.resize(
        (int(shot.width * scale), int(shot.height * scale)), Image.Resampling.LANCZOS
    )
    device = frame_phone(scaled)
    shadowed = drop_shadow(device)

    phone_x = (CANVAS_W - shadowed.width) // 2
    phone_y = int(CANVAS_H * 0.285)
    bg.paste(shadowed, (phone_x, phone_y), shadowed)

    draw = ImageDraw.Draw(bg)
    dots_y = phone_y + shadowed.height - 18
    if dots_y > CANVAS_H - 70:
        dots_y = CANVAS_H - 70
    draw_progress_dots(draw, slide.index, slide.total, dots_y)

    out_path = out_dir / slide.output
    bg.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


def stitch_panorama(out_dir: Path, paths: list[Path]) -> Path:
    images = [Image.open(p).convert("RGB") for p in paths]
    scale = 0.28
    thumbs = [
        im.resize((int(im.width * scale), int(im.height * scale)), Image.Resampling.LANCZOS)
        for im in images
    ]
    gap = 18
    width = sum(t.width for t in thumbs) + gap * (len(thumbs) - 1)
    height = max(t.height for t in thumbs)
    strip = Image.new("RGB", (width, height), MIST)
    x = 0
    for thumb in thumbs:
        strip.paste(thumb, (x, 0))
        x += thumb.width + gap
    path = out_dir / "_series-preview.png"
    strip.save(path, "PNG", optimize=True)
    return path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    raw_dir = root / "AppStoreScreenshots" / "6.7-inch"
    out_dir = root / "AppStoreScreenshots" / "marketing" / "6.7-inch"
    out_dir.mkdir(parents=True, exist_ok=True)

    missing = [s.source for s in SLIDES if not (raw_dir / s.source).exists()]
    if missing:
        print(f"Missing raw screenshots in {raw_dir}: {', '.join(missing)}", file=sys.stderr)
        print("Run Scripts/capture_app_store_screenshots.sh first.", file=sys.stderr)
        return 1

    fonts = load_fonts()
    written: list[Path] = []
    for slide in SLIDES:
        path = compose_slide(raw_dir, out_dir, fonts, slide)
        print(f"  • {path.name}")
        written.append(path)

    preview = stitch_panorama(out_dir, written)
    print(f"  • {preview.name} (series preview)")
    print(f"→ Saved to {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
