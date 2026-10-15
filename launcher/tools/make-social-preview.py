"""Draws the repository's social preview (1280x640), the picture shown when the GitHub link is shared.

    py -P launcher/tools/make-social-preview.py docs/images/social-preview.png

Built from docs/images/logo.png (the sticker, from make-wordmark.py) and docs/images/icon.png
(the launcher's cassette, from make-icon.ps1 -PngOut). Needs Pillow, numpy, scipy and Segoe UI.
Upload it on GitHub: Settings > General > Social preview > Edit > Upload an image.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

OUT = sys.argv[1] if len(sys.argv) > 1 else "social-preview.png"
HERE = os.path.dirname(os.path.abspath(__file__))
IMAGES = os.path.join(HERE, "..", "..", "docs", "images")
W, H = 1280, 640
TOP, BOTTOM = (34, 17, 66), (11, 9, 24)
PINK, CYAN, TEXT, DIM = (255, 62, 165), (45, 226, 230), (245, 240, 255), (176, 164, 214)
BLACK = r"C:\Windows\Fonts\seguibl.ttf"
BOLD = r"C:\Windows\Fonts\segoeuib.ttf"


def sticker_without_background(path):
    """The sticker on transparency: the dark area that reaches the image's edge is cut away,
    the dark gaps inside the purple outline stay."""
    img = Image.open(path).convert("RGBA")
    a = np.asarray(img).astype(np.int16)
    dark = (a[..., :3].max(axis=2) < 40)
    labels, _ = ndimage.label(dark)
    edge = set(np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))) - {0}
    outside = np.isin(labels, list(edge))
    outside = ndimage.binary_erosion(~outside, iterations=1)   # soften by one pixel
    alpha = (outside * 255).astype(np.uint8)
    img.putalpha(Image.fromarray(alpha).filter(__import__("PIL.ImageFilter", fromlist=["GaussianBlur"]).GaussianBlur(0.8)))
    return img.crop(img.getbbox())


# background: dark purple gradient, a neon horizon grid at the bottom
bg = Image.new("RGB", (W, H))
px = np.zeros((H, W, 3), np.float32)
for c in range(3):
    px[..., c] = np.linspace(TOP[c], BOTTOM[c], H)[:, None]
bg = Image.fromarray(px.astype(np.uint8))
grid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
g = ImageDraw.Draw(grid)
horizon = 470
for i in range(9):                                    # receding horizontal lines
    y = horizon + int((i / 8) ** 1.8 * (H - horizon))
    g.line([(0, y), (W, y)], fill=PINK + (40 + i * 6,), width=2)
for i in range(-14, 15):                              # lines to the vanishing point
    g.line([(W / 2 + i * 26, horizon), (W / 2 + i * 260, H)], fill=PINK + (45,), width=2)
bg = Image.alpha_composite(bg.convert("RGBA"), grid)

# the sticker on the left
sticker = sticker_without_background(os.path.join(IMAGES, "logo.png"))
sh = 500
sticker = sticker.resize((int(sticker.width * sh / sticker.height), sh), Image.LANCZOS)
bg.alpha_composite(sticker, (70, (H - sh) // 2))

# the right column: the cassette and three lines
right = 70 + sticker.width + 70
icon = Image.open(os.path.join(IMAGES, "icon.png")).convert("RGBA").resize((150, 150), Image.LANCZOS)
d = ImageDraw.Draw(bg)
y = 120
bg.alpha_composite(icon, (right, y))
y += 150 + 26
for text, font, size, colour, gap in (
    ("CO-OP MULTIPLAYER FOR", BLACK, 30, CYAN, 8),
    ("RETRO REWIND", BLACK, 58, TEXT, 18),
    ("Run one video store together", BOLD, 30, DIM, 14),
    ("Free  ·  Windows  ·  over Steam", BOLD, 26, PINK, 0),
):
    f = ImageFont.truetype(font, size)
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    d.text((right - l, y - t), text, font=f, fill=colour)
    y += (b - t) + gap
bg.convert("RGB").save(OUT)
print("wrote", OUT)
