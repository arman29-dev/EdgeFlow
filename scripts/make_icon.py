#!/usr/bin/env python3
"""Generates assets/AppIcon.png (1024x1024): a trackpad with a brightness strip on the left and a volume strip on the right.
Optional: the repository already contains the PNG. Needs Pillow (pip install pillow). Original artwork, no third-party assets."""
import os
from PIL import Image, ImageDraw, ImageFilter

SS = 4                      # supersampling factor
N = 1024 * SS


def s(v):
    return int(round(v * SS))


def rrect_mask(box, radius):
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle([s(box[0]), s(box[1]), s(box[2]), s(box[3])], radius=s(radius), fill=255)
    return m


def vertical_gradient(top, bottom):
    img = Image.new("RGBA", (N, N))
    px = img.load()
    for y in range(N):
        t = y / (N - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(N):
            px[x, y] = c
    return img


canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

# --- icon body (Apple-style margin: 100px around an 824px rounded square) ---
body_box = (100, 100, 924, 924)
body_mask = rrect_mask(body_box, 186)

# soft drop shadow
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 110), mask=rrect_mask((100, 118, 924, 942), 186))
shadow = shadow.filter(ImageFilter.GaussianBlur(s(18)))
canvas = Image.alpha_composite(canvas, shadow)

# background gradient + subtle top sheen
bg = vertical_gradient((38, 44, 140), (24, 112, 230))
sheen = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(sheen).ellipse([s(-200), s(-560), s(1224), s(380)], fill=(255, 255, 255, 34))
sheen = sheen.filter(ImageFilter.GaussianBlur(s(70)))
bg = Image.alpha_composite(bg, sheen)
body = Image.new("RGBA", (N, N), (0, 0, 0, 0))
body.paste(bg, mask=body_mask)
canvas = Image.alpha_composite(canvas, body)

# --- trackpad ---
pad_box = (222, 332, 802, 692)           # 580 x 360, roughly a real trackpad's proportions
pad_radius = 58
pad_mask = rrect_mask(pad_box, pad_radius)

pad_shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
pad_shadow.paste((10, 20, 80, 120), mask=rrect_mask((222, 346, 802, 706), pad_radius))
pad_shadow = pad_shadow.filter(ImageFilter.GaussianBlur(s(14)))
canvas = Image.alpha_composite(canvas, pad_shadow)

pad = Image.new("RGBA", (N, N), (0, 0, 0, 0))
pad_fill = vertical_gradient((250, 251, 255), (222, 229, 246))
pad.paste(pad_fill, mask=pad_mask)

# edge strips: left = brightness (amber), right = volume (cyan), clipped to the pad shape
strip_w = int(580 * 0.17)
left_strip = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(left_strip).rectangle([s(pad_box[0]), s(pad_box[1]), s(pad_box[0] + strip_w), s(pad_box[3])], fill=(255, 183, 40, 255))
right_strip = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(right_strip).rectangle([s(pad_box[2] - strip_w), s(pad_box[1]), s(pad_box[2]), s(pad_box[3])], fill=(30, 200, 232, 255))
clipped = Image.new("RGBA", (N, N), (0, 0, 0, 0))
for strip in (left_strip, right_strip):
    clipped = Image.alpha_composite(clipped, strip)
final_strips = Image.new("RGBA", (N, N), (0, 0, 0, 0))
final_strips.paste(clipped, mask=pad_mask)
pad = Image.alpha_composite(pad, final_strips)
canvas = Image.alpha_composite(canvas, pad)

# --- glyphs ---
NAVY = (22, 32, 96, 255)
d = ImageDraw.Draw(canvas)
cy = (pad_box[1] + pad_box[3]) / 2
lx = pad_box[0] + strip_w / 2
rx = pad_box[2] - strip_w / 2


def line(points, width):
    pts = [(s(x), s(y)) for x, y in points]
    d.line(pts, fill=NAVY, width=s(width), joint="curve")
    r = s(width) / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=NAVY)


G = 1.3   # glyph scale


def chevron(cx, y, up):
    k = -1 if up else 1
    line([(cx - 17 * G, y - 7 * G * k), (cx, y + 7 * G * k), (cx + 17 * G, y - 7 * G * k)], 9 * G)


# sun (brightness)
import math
d.ellipse([s(lx - 15 * G), s(cy - 15 * G), s(lx + 15 * G), s(cy + 15 * G)], fill=NAVY)
for i in range(8):
    a = math.radians(i * 45)
    line([(lx + 25 * G * math.cos(a), cy + 25 * G * math.sin(a)), (lx + 36 * G * math.cos(a), cy + 36 * G * math.sin(a))], 6 * G)

# speaker (volume)
sx = rx - 8
d.rectangle([s(sx - 20 * G), s(cy - 11 * G), s(sx - 5 * G), s(cy + 11 * G)], fill=NAVY)
d.polygon([(s(sx - 7 * G), s(cy - 11 * G)), (s(sx + 12 * G), s(cy - 26 * G)), (s(sx + 12 * G), s(cy + 26 * G)), (s(sx - 7 * G), s(cy + 11 * G))], fill=NAVY)
d.arc([s(sx + 2 * G), s(cy - 18 * G), s(sx + 30 * G), s(cy + 18 * G)], -55, 55, fill=NAVY, width=s(6 * G))

# up / down chevrons on both strips
for cx in (lx, rx):
    chevron(cx, cy - 100, up=True)
    chevron(cx, cy + 100, up=False)

# --- finish ---
out = canvas.resize((1024, 1024), Image.LANCZOS)
here = os.path.dirname(os.path.abspath(__file__))
dest = os.path.join(here, "..", "assets")
os.makedirs(dest, exist_ok=True)
path = os.path.join(dest, "AppIcon.png")
out.save(path)
print("wrote", os.path.normpath(path))
