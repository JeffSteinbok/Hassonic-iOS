#!/usr/bin/env python3
"""Draws Demo/living-room.png, the made-up room the screenshots show.

A top-down living room in flat shapes, so no real home is in the README:
oak floor, rug, sofa and armchairs, coffee table, TV console, lamps and
plants. Hotspot positions in Demo/demo-config.yaml match this layout, so
move both together.
"""

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

W, H = 1200, 1300
S = 2  # drawn at twice the size, then scaled down for smooth edges
WALL = 34
OUT = Path(__file__).resolve().parent / "living-room.png"

image = Image.new("RGB", (W * S, H * S), "#2b2b2e")
draw = ImageDraw.Draw(image)


def rect(x0, y0, x1, y1, fill, r=0, outline=None, w=0):
    draw.rounded_rectangle([x0 * S, y0 * S, x1 * S, y1 * S], radius=r * S, fill=fill, outline=outline, width=w * S)


def oval(cx, cy, rx, ry, fill, outline=None, w=0):
    draw.ellipse([(cx - rx) * S, (cy - ry) * S, (cx + rx) * S, (cy + ry) * S], fill=fill, outline=outline, width=w * S)


def shadow(boxes, offset=10, radius=16):
    """A soft drop shadow under each (x0, y0, x1, y1, corner) box."""
    global image, draw
    mask = Image.new("L", image.size, 0)
    mask_draw = ImageDraw.Draw(mask)
    for x0, y0, x1, y1, r in boxes:
        mask_draw.rounded_rectangle([(x0 + offset) * S, (y0 + offset) * S, (x1 + offset) * S, (y1 + offset) * S],
                                    radius=r * S, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(14 * S)).point(lambda v: int(v * 0.45))
    image = Image.composite(Image.new("RGB", image.size, (40, 28, 18)), image, mask)
    draw = ImageDraw.Draw(image)


# Oak floor, plank by plank.
rect(WALL, WALL, W - WALL, H - WALL, "#c49a6c")
random.seed(4)
for y in range(WALL, H - WALL, 46):
    x = WALL - random.randint(0, 300)
    while x < W - WALL:
        length = random.randint(220, 420)
        x0, x1 = max(x, WALL), min(x + length, W - WALL)
        if x1 > x0:
            shade = random.randint(-14, 14)
            rect(x0, y, x1, min(y + 46, H - WALL), (196 + shade, 154 + shade, 108 + shade))
            draw.line([(x0 * S, y * S), (x0 * S, min(y + 46, H - WALL) * S)], fill=(150, 112, 76), width=S)
        x += length
    draw.line([(WALL * S, (y + 46) * S), ((W - WALL) * S, (y + 46) * S)], fill=(160, 120, 82), width=S)

# Rug.
shadow([(250, 470, 950, 1010, 8)])
rect(250, 470, 950, 1010, "#d8cdbb", r=8)
rect(280, 500, 920, 980, "#e6ddcf", r=6, outline="#b9a98f", w=3)
for i in range(7):
    rect(300 + i * 88, 520, 330 + i * 88, 960, "#ded3c2", r=4)

# Sofa along the bottom, an armchair either side.
shadow([(300, 1030, 900, 1190, 36), (150, 560, 300, 760, 30), (900, 560, 1050, 760, 30)])
rect(300, 1030, 900, 1190, "#5a6f86", r=36)
rect(340, 1040, 860, 1100, "#6c8299", r=24)
for x0 in (340, 513, 686):
    rect(x0 + 6, 1100, x0 + 168, 1176, "#7b91a8", r=18)
rect(310, 1060, 350, 1180, "#4e6177", r=16)
rect(850, 1060, 890, 1180, "#4e6177", r=16)
oval(420, 1070, 46, 26, "#e5b85c")
oval(780, 1070, 46, 26, "#d9d4c9")
for x0 in (150, 900):
    rect(x0, 560, x0 + 150, 760, "#a4613f", r=30)
    rect(x0 + 22, 585, x0 + 128, 735, "#b9744f", r=22)

# Coffee table with a plant and a book.
shadow([(450, 680, 750, 830, 16)])
rect(450, 680, 750, 830, "#6b4a33", r=16)
rect(462, 692, 738, 818, "#7d573c", r=12)
oval(540, 745, 34, 34, "#f1efe9")
oval(540, 745, 20, 20, "#9cc28a")
rect(630, 720, 700, 770, "#2f4a62", r=4)

# TV on a console against the top wall.
shadow([(360, 70, 840, 150, 8)])
rect(360, 70, 840, 150, "#4a3527", r=8)
rect(400, 52, 800, 72, "#121214", r=4)

# Side tables with lamps beside the sofa.
for cx in (240, 960):
    shadow([(cx - 55, 1050, cx + 55, 1160, 55)])
    oval(cx, 1105, 55, 55, "#6b4a33")
    oval(cx, 1105, 32, 32, "#f3ead6", outline="#d8c9a6", w=3)
    oval(cx, 1105, 8, 8, "#b08d57")

# Floor lamps in the top corners.
for cx in (110, 1090):
    oval(cx, 130, 42, 42, "#efe6d2", outline="#c9b892", w=3)
    oval(cx, 130, 10, 10, "#3a3a3a")

# Plants.
for cx, cy in ((110, 1200), (1090, 330)):
    oval(cx, cy, 58, 58, "#3f6b3f")
    for a in range(8):
        oval(cx + math.cos(a) * 30, cy + math.sin(a) * 30, 24, 14, "#5c8f4c")

# Bookshelf on the left wall.
rect(WALL, 300, 90, 520, "#5a4030")
for i in range(9):
    rect(WALL + 6, 310 + i * 23, 84, 328 + i * 23,
         random.choice(["#8a4b3c", "#3d5a73", "#c49a3c", "#6d7a52", "#7a5c8a"]))

# The ceiling light, seen from above.
oval(600, 420, 26, 26, "#f6f1e3", outline="#cbbf9e", w=3)

# Walls, windows and a doorway.
for box in [(0, 0, W, WALL), (0, 0, WALL, H), (W - WALL, 0, W, H), (0, H - WALL, W, H)]:
    rect(*box, "#2b2b2e")
for x0 in (170, 780):
    rect(x0, 6, x0 + 250, WALL, "#cfe6f3")
    draw.line([((x0 + 125) * S, 6 * S), ((x0 + 125) * S, WALL * S)], fill="#e9eef2", width=3 * S)
rect(W - WALL, 880, W, 1030, "#c49a6c")

image.resize((W, H), Image.LANCZOS).save(OUT, optimize=True)
print(f"wrote {OUT}")
