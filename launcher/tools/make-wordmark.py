"""Draws the REWIND TOGETHER sticker logo as a square PNG, for Discord and anywhere else square.

    py -P launcher/tools/make-wordmark.py dist/discord/logo-wordmark.png [size] [transparent]

With "transparent", everything outside the sticker is see-through and the picture is cropped to
it (docs/images/logo.png, for the README on light and dark pages alike).

Needs Pillow, numpy, scipy and Windows' Segoe UI Black. An original mark in the bright sticker
style of the game's own logo: an "RT" monogram whose T ends in a rewind arrow, the two words in
pink and cyan, one purple outline around the lot. Drawn at twice the size, then scaled down.
"""
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

OUT = sys.argv[1] if len(sys.argv) > 1 else "logo-wordmark.png"
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
TRANSPARENT = len(sys.argv) > 3 and sys.argv[3] == "transparent"
S = SIZE * 2                                  # working size
BG = (10, 9, 14)
PINK = (255, 24, 146)
CYAN = (16, 200, 245)
PURPLE = (150, 36, 196)
FONT = r"C:\Windows\Fonts\seguibl.ttf"


def font(size):
    return ImageFont.truetype(FONT, size)


def text_box(text, f):
    l, t, r, b = f.getbbox(text)
    return l, t, r - l, b - t


def fit_font(text, width):
    """The font size at which text's ink is width pixels wide."""
    size = 400
    return max(10, int(size * width / text_box(text, font(size))[2]))


def u(x):
    """A length given in 1/1000ths of the image."""
    return int(round(x * S / 1000))


# --------------------------------------------------------------- layout
pink = Image.new("L", (S, S), 0)
cyan = Image.new("L", (S, S), 0)
dp, dc = ImageDraw.Draw(pink), ImageDraw.Draw(cyan)

# The monogram: R for Rewind in pink, T for Together in cyan, set tight.
f_mono = font(u(370))
rl, rt, rw, cap = text_box("R", f_mono)       # cap = the R's ink height
tl, tt, tw, _ = text_box("T", f_mono)
gap = int(cap * 0.05)
mx = (S - (rw + gap + tw)) // 2
my = u(100)
base = my + cap                               # baseline
dp.text((mx - rl, my - rt), "R", font=f_mono, fill=255)
dc.text((mx + rw + gap - tl, my - tt), "T", font=f_mono, fill=255)

# The two words, centred under the monogram.
y = base + u(44)
for word, layer, draw in (("REWIND", pink, dp), ("TOGETHER", cyan, dc)):
    f = font(fit_font(word, u(690)))
    l, t, w, hh = text_box(word, f)
    draw.text(((S - w) // 2 - l, y - t), word, font=f, fill=255)
    y += hh + u(26)

# --------------------------------------------------------------- the sticker outline
pink_a = np.asarray(pink, dtype=np.float32) / 255
cyan_a = np.asarray(cyan, dtype=np.float32) / 255
ink = (pink_a + cyan_a) > 0.5

GAP, BAND, SMOOTH = u(14), u(24), u(60)       # dark gap, purple band, how much the outline rounds off
away = ndimage.distance_transform_edt(~ink)    # distance from the letters
outline = away <= GAP + BAND + SMOOTH
outline = ndimage.distance_transform_edt(outline) > SMOOTH          # closing: one smooth shape
outline = ndimage.binary_fill_holes(outline)                         # no scraps between letters
band = outline & (ndimage.distance_transform_edt(outline) <= BAND)   # only its outer rim is purple

# Centre the sticker vertically.
rows = np.nonzero(outline.any(axis=1))[0]
shift = (S - (rows[-1] - rows[0] + 1)) // 2 - rows[0]
pink_a, cyan_a, band, outline = (np.roll(a, shift, axis=0) for a in (pink_a, cyan_a, band, outline))

# --------------------------------------------------------------- paint
img = np.empty((S, S, 3), dtype=np.float32)
img[:] = BG
band_a = ndimage.uniform_filter(band.astype(np.float32), 3)          # soften the band's stair steps
for colour, alpha in ((PURPLE, band_a), (PINK, pink_a), (CYAN, cyan_a)):
    img = img * (1 - alpha[..., None]) + np.array(colour, np.float32) * alpha[..., None]
out = Image.fromarray(np.clip(img + 0.5, 0, 255).astype(np.uint8), "RGB")
if TRANSPARENT:
    alpha = ndimage.uniform_filter(outline.astype(np.float32), 3) * 255
    out = out.convert("RGBA")
    out.putalpha(Image.fromarray(np.clip(alpha + 0.5, 0, 255).astype(np.uint8), "L"))
    out = out.resize((SIZE, SIZE), Image.LANCZOS)
    out.crop(out.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()).save(OUT)
else:
    out.resize((SIZE, SIZE), Image.LANCZOS).save(OUT)
print("wrote", OUT)
