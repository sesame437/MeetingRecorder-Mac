#!/usr/bin/env python3
"""Generate MeetingRecorder app icon and convert to .icns"""
import math
import os
import subprocess
import sys
from PIL import Image, ImageDraw

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024  # base size, will be scaled down for iconset


def draw_rounded_rect(draw, xy, radius, fill):
    x0, y0, x1, y1 = xy
    draw.rectangle([x0 + radius, y0, x1 - radius, y1], fill=fill)
    draw.rectangle([x0, y0 + radius, x1, y1 - radius], fill=fill)
    draw.pieslice([x0, y0, x0 + 2 * radius, y0 + 2 * radius], 180, 270, fill=fill)
    draw.pieslice([x1 - 2 * radius, y0, x1, y0 + 2 * radius], 270, 360, fill=fill)
    draw.pieslice([x0, y1 - 2 * radius, x0 + 2 * radius, y1], 90, 180, fill=fill)
    draw.pieslice([x1 - 2 * radius, y1 - 2 * radius, x1, y1], 0, 90, fill=fill)


def lerp_color(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def create_icon(size=1024):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Background: rounded rectangle with gradient (top-left blue to bottom-right teal)
    margin = int(size * 0.02)
    radius = int(size * 0.22)
    color_top = (30, 60, 150)      # deep blue
    color_bottom = (0, 180, 180)   # teal

    # Draw gradient by horizontal stripes
    for y in range(margin, size - margin):
        t = (y - margin) / (size - 2 * margin)
        color = lerp_color(color_top, color_bottom, t)
        draw.rectangle([margin + radius // 2, y, size - margin - radius // 2, y + 1], fill=color)

    # Overdraw full rounded rect with mid color, then re-draw gradient
    # Simpler: draw rounded rect as solid, then overlay gradient
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)
    for y in range(size):
        t = y / size
        color = lerp_color(color_top, color_bottom, t)
        bg_draw.rectangle([0, y, size, y + 1], fill=(*color, 255))

    # Create mask with rounded rect
    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    draw_rounded_rect(mask_draw, (margin, margin, size - margin, size - margin), radius, 255)

    img = Image.composite(bg, Image.new("RGBA", (size, size), (0, 0, 0, 0)), mask)
    draw = ImageDraw.Draw(img)

    # --- Microphone icon ---
    cx, cy = size // 2, size // 2 - int(size * 0.04)
    white = (255, 255, 255, 240)
    white_dim = (255, 255, 255, 120)

    # Mic body (rounded rectangle)
    mic_w = int(size * 0.16)
    mic_h = int(size * 0.28)
    mic_r = mic_w // 2
    mic_x0 = cx - mic_w // 2
    mic_y0 = cy - mic_h // 2
    mic_x1 = cx + mic_w // 2
    mic_y1 = cy + mic_h // 2
    draw_rounded_rect(draw, (mic_x0, mic_y0, mic_x1, mic_y1), mic_r, white)

    # Mic grille lines
    line_w = 2
    for i in range(3):
        ly = mic_y0 + mic_h // 4 + i * int(mic_h * 0.18)
        draw.rectangle([mic_x0 + mic_w // 4, ly, mic_x1 - mic_w // 4, ly + line_w],
                       fill=lerp_color(color_top, color_bottom, 0.5) + (180,))

    # Arc (U-shape around mic)
    arc_margin = int(size * 0.06)
    arc_w = 6
    arc_bbox = [
        mic_x0 - arc_margin,
        mic_y0 + int(mic_h * 0.15),
        mic_x1 + arc_margin,
        mic_y1 + arc_margin + int(size * 0.04),
    ]
    draw.arc(arc_bbox, 0, 180, fill=white, width=int(size * 0.025))

    # Stem below arc
    stem_x = cx
    stem_top = arc_bbox[3] - int(size * 0.01)
    stem_bottom = stem_top + int(size * 0.10)
    stem_w = int(size * 0.025)
    draw.rectangle([stem_x - stem_w // 2, stem_top, stem_x + stem_w // 2, stem_bottom], fill=white)

    # Base
    base_w = int(size * 0.14)
    base_h = int(size * 0.025)
    draw.rounded_rectangle(
        [cx - base_w // 2, stem_bottom, cx + base_w // 2, stem_bottom + base_h],
        radius=base_h // 2, fill=white
    )

    # --- Record dot (top-right) ---
    dot_r = int(size * 0.08)
    dot_cx = cx + int(size * 0.22)
    dot_cy = cy - int(size * 0.20)
    draw.ellipse([dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r],
                 fill=(255, 60, 60, 255))
    # Inner highlight
    hi_r = int(dot_r * 0.45)
    draw.ellipse([dot_cx - hi_r, dot_cy - hi_r - 1, dot_cx + hi_r, dot_cy + hi_r - 1],
                 fill=(255, 120, 120, 200))

    # --- Subtle sound waves (left and right of mic) ---
    for side in [-1, 1]:
        for i, alpha in enumerate([100, 60, 35]):
            wave_r = int(size * 0.18) + i * int(size * 0.06)
            wave_w = int(size * 0.018)
            wave_cx = cx + side * int(size * 0.02)
            bbox = [wave_cx - wave_r, cy - wave_r, wave_cx + wave_r, cy + wave_r]
            start_angle = 120 if side == 1 else 0
            end_angle = 240 if side == 1 else 60  # partial arc
            if side == -1:
                start_angle = 300
                end_angle = 60
            draw.arc(bbox, start_angle, end_angle,
                     fill=(255, 255, 255, alpha), width=wave_w)

    return img


def create_iconset(base_img, output_dir):
    """Create .iconset directory with all required sizes"""
    os.makedirs(output_dir, exist_ok=True)
    sizes = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]
    for size, scale in sizes:
        px = size * scale
        resized = base_img.resize((px, px), Image.LANCZOS)
        if scale == 1:
            name = f"icon_{size}x{size}.png"
        else:
            name = f"icon_{size}x{size}@2x.png"
        resized.save(os.path.join(output_dir, name))
        print(f"  {name} ({px}x{px})")


def main():
    print("Generating icon...")
    icon = create_icon(1024)

    # Save preview
    preview_path = os.path.join(SCRIPT_DIR, "AppIcon_preview.png")
    icon.save(preview_path)
    print(f"Preview: {preview_path}")

    # Create .iconset
    iconset_dir = os.path.join(SCRIPT_DIR, "AppIcon.iconset")
    create_iconset(icon, iconset_dir)

    # Convert to .icns
    icns_path = os.path.join(SCRIPT_DIR, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", icns_path], check=True)
    print(f"Icon: {icns_path}")

    # Cleanup iconset
    import shutil
    shutil.rmtree(iconset_dir)
    print("Done!")


if __name__ == "__main__":
    main()
