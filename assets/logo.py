"""Tank Tools logo generator.

Renders assets/logo.png (400x400) and assets/logo-64.png from vector
primitives, so the mark can be recoloured or resized by editing the constants
at the top rather than by re-cutting a bitmap. Requires Pillow.

    python assets/logo.py

The unused variant_* functions are kept deliberately: they are the rejected
directions, and are cheaper to revisit than to rebuild.
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

S    = 4                 # supersample
N    = 400
C    = N * S
OUT  = os.path.dirname(os.path.abspath(__file__))

BG        = (22, 24, 29)
BG_EDGE   = (12, 13, 16)
BORDER    = (58, 63, 74)
YELLOW    = (255, 235, 38)
INK       = (0, 0, 0)
PLATE_DIM = (74, 80, 92)
PLATE_LIT = (150, 158, 172)

def blank():
    return Image.new("RGBA", (C, C), (0, 0, 0, 0))

def stroke(shape_fn, radius, color, base):
    """Emulate an even outline by stamping the shape around a circle."""
    steps = 72
    for i in range(steps):
        a = 2 * math.pi * i / steps
        shape_fn(base, round(math.cos(a) * radius), round(math.sin(a) * radius), color)

# ---------------------------------------------------------------- backdrop
def backdrop(img, rounded=True):
    d = ImageDraw.Draw(img)
    r = int(C * 0.18)
    box = [0, 0, C - 1, C - 1]
    if rounded:
        d.rounded_rectangle(box, radius=r, fill=BG)
    else:
        d.rectangle(box, fill=BG)

    # vignette: darker toward the edges
    vg = Image.new("L", (C, C), 0)
    vd = ImageDraw.Draw(vg)
    rings = 90
    for i in range(rings):
        t = i / rings
        inset = int(t * C * 0.5)
        vd.ellipse([inset - C * 0.12, inset - C * 0.12,
                    C - inset + C * 0.12, C - inset + C * 0.12],
                   fill=int(150 * (t ** 2.2)))
    vg = vg.filter(ImageFilter.GaussianBlur(C * 0.02))
    dark = Image.new("RGBA", (C, C), BG_EDGE + (255,))
    inner = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    if rounded:
        ImageDraw.Draw(inner).rounded_rectangle(box, radius=r, fill=(255, 255, 255, 255))
    else:
        ImageDraw.Draw(inner).rectangle(box, fill=(255, 255, 255, 255))
    vg = Image.composite(vg, Image.new("L", (C, C), 0), inner.split()[3])
    img.alpha_composite(Image.composite(dark, Image.new("RGBA", (C, C), (0, 0, 0, 0)),
                                        vg).convert("RGBA"))
    if rounded:
        d.rounded_rectangle(box, radius=r, outline=BORDER, width=int(C * 0.012))

# ---------------------------------------------------------------- the bang
def bang(img, cx, cy, h, dx=0, dy=0, color=YELLOW):
    """Tapered exclamation mark centred on (cx, cy), total height h.

    Flat ends: circular end-caps on a tapered stem protrude past the taper and
    read as lumps at icon sizes. Proportions are set so stem+gap+dot == h, and
    the gap clears twice the outline width so the two halves stay separate.
    """
    d = ImageDraw.Draw(img)
    cx += dx; cy += dy
    stem_h = h * 0.600
    gap    = h * 0.180
    dot_d  = h * 0.220
    w_top  = h * 0.260
    w_bot  = h * 0.170
    top    = cy - h / 2

    d.polygon([(cx - w_top / 2, top),
               (cx + w_top / 2, top),
               (cx + w_bot / 2, top + stem_h),
               (cx - w_bot / 2, top + stem_h)], fill=color)
    dy0 = top + stem_h + gap
    d.ellipse([cx - dot_d / 2, dy0, cx + dot_d / 2, dy0 + dot_d], fill=color)

def bang_outlined(img, cx, cy, h, ow):
    ol = blank()
    stroke(lambda b, dx, dy, col: bang(b, cx, cy, h, dx, dy, col), ow, INK, ol)
    img.alpha_composite(ol)
    lyr = blank()
    bang(lyr, cx, cy, h)
    img.alpha_composite(lyr)

# ---------------------------------------------------------------- nameplate
def plate(img, cx, cy, w, h, fill_frac=0.62, dx=0, dy=0, solid=None):
    d = ImageDraw.Draw(img)
    cx += dx; cy += dy
    box = [cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2]
    r = h * 0.34
    if solid:
        d.rounded_rectangle(box, radius=r, fill=solid)
        return
    d.rounded_rectangle(box, radius=r, fill=(38, 41, 48), outline=PLATE_DIM,
                        width=int(C * 0.009))
    inset = int(C * 0.014)
    fb = [box[0] + inset, box[1] + inset,
          box[0] + inset + (w - 2 * inset) * fill_frac, box[3] - inset]
    d.rounded_rectangle(fb, radius=r * 0.6, fill=PLATE_LIT)

# ================================================================ variant A
def variant_a():
    img = blank()
    backdrop(img)
    bang_outlined(img, C * 0.335, C * 0.475, C * 0.50, int(C * 0.026))
    pl = blank()
    stroke(lambda b, dx, dy, col: plate(b, C * 0.655, C * 0.475, C * 0.30,
                                        C * 0.115, dx=dx, dy=dy, solid=col),
           int(C * 0.026), INK, pl)
    img.alpha_composite(pl)
    lyr = blank()
    plate(lyr, C * 0.655, C * 0.475, C * 0.30, C * 0.115)
    img.alpha_composite(lyr)
    return img

# ================================================================ variant B
def qbez(p0, p1, p2, n=60):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1])
            for t in (i / n for i in range(n + 1))]

def shield_pts(cx, cy, w, h, dx=0, dy=0):
    cx += dx; cy += dy
    l, r = cx - w / 2, cx + w / 2
    t, b = cy - h / 2, cy + h / 2
    sh = t + h * 0.52
    pts  = [(l, t + h * 0.06)]
    pts += qbez((l, t + h * 0.06), (l, t), (l + w * 0.10, t))
    pts += [(r - w * 0.10, t)]
    pts += qbez((r - w * 0.10, t), (r, t), (r, t + h * 0.06))
    pts += [(r, sh)]
    pts += qbez((r, sh), (r, b - h * 0.10), (cx, b))
    pts += qbez((cx, b), (l, b - h * 0.10), (l, sh))
    return pts

def variant_b():
    img = blank()
    backdrop(img)
    sw, shh = C * 0.575, C * 0.68
    scx, scy = C * 0.50, C * 0.485

    sh = blank()
    stroke(lambda b, dx, dy, col: ImageDraw.Draw(b).polygon(
        shield_pts(scx, scy, sw, shh, dx, dy), fill=col), int(C * 0.028), INK, sh)
    img.alpha_composite(sh)

    body = blank()
    ImageDraw.Draw(body).polygon(shield_pts(scx, scy, sw, shh), fill=YELLOW)
    # knock the bang out of the shield
    hole = Image.new("L", (C, C), 255)
    hl = blank()
    bang(hl, scx, scy - shh * 0.055, shh * 0.70, color=(255, 255, 255, 255))
    hole = Image.composite(Image.new("L", (C, C), 0), hole, hl.split()[3])
    body.putalpha(Image.composite(body.split()[3], Image.new("L", (C, C), 0), hole))
    img.alpha_composite(body)
    return img

# ================================================================ variant C
def variant_c():
    img = blank()
    backdrop(img)
    d = ImageDraw.Draw(img)
    for i, fy in enumerate((0.775, 0.858)):
        w = C * (0.46 if i == 0 else 0.34)
        h = C * 0.043
        box = [C * 0.5 - w / 2, C * fy - h / 2, C * 0.5 + w / 2, C * fy + h / 2]
        d.rounded_rectangle(box, radius=h / 2, fill=(48, 52, 61))
    bang_outlined(img, C * 0.50, C * 0.415, C * 0.60, int(C * 0.028))
    return img



# ================================================================ variant D
# Variant A's layout -- bang left, object right -- with a knight's heater
# shield in place of the health bar.

STEEL_HI  = (196, 204, 218)
STEEL_LO  = (104, 113, 130)
STEEL_RIM = (228, 234, 245)

def heater_pts(cx, cy, w, h, dx=0, dy=0):
    """Classic heater shield: flat top with rounded shoulders, straight-ish
    upper flanks, then a long sweep into a point at the bottom."""
    cx += dx; cy += dy
    l, r = cx - w / 2, cx + w / 2
    t, b = cy - h / 2, cy + h / 2
    sh   = t + h * 0.40          # where the flanks start curving in
    cr   = w * 0.14              # shoulder corner radius

    pts  = [(l, sh)]
    pts += qbez((l, t + cr), (l, t), (l + cr, t))          # left shoulder
    pts += [(r - cr, t)]
    pts += qbez((r - cr, t), (r, t), (r, t + cr))          # right shoulder
    pts += [(r, sh)]
    pts += qbez((r, sh), (r, b - h * 0.22), (cx, b))       # right sweep to tip
    pts += qbez((cx, b), (l, b - h * 0.22), (l, sh))       # left sweep back
    return pts

def vgrad(top_rgb, bot_rgb):
    g = Image.new("RGBA", (1, C))
    px = g.load()
    for y in range(C):
        t = y / (C - 1)
        px[0, y] = (round(top_rgb[0] + (bot_rgb[0] - top_rgb[0]) * t),
                    round(top_rgb[1] + (bot_rgb[1] - top_rgb[1]) * t),
                    round(top_rgb[2] + (bot_rgb[2] - top_rgb[2]) * t), 255)
    return g.resize((C, C))

def knight_shield(img, cx, cy, w, h, ow, steel=True):
    # black keyline, same stamped-offset trick as the bang
    ol = blank()
    stroke(lambda b, dx, dy, col: ImageDraw.Draw(b).polygon(
        heater_pts(cx, cy, w, h, dx, dy), fill=col), ow, INK, ol)
    img.alpha_composite(ol)

    mask = Image.new("L", (C, C), 0)
    ImageDraw.Draw(mask).polygon(heater_pts(cx, cy, w, h), fill=255)

    if steel:
        body = vgrad(STEEL_HI, STEEL_LO)
        # centre ridge: a soft vertical highlight so it reads as beaten metal
        ridge = Image.new("L", (C, C), 0)
        rd = ImageDraw.Draw(ridge)
        rw = w * 0.16
        rd.polygon([(cx - rw / 2, cy - h / 2), (cx + rw / 2, cy - h / 2),
                    (cx + rw * 0.30, cy + h / 2), (cx - rw * 0.30, cy + h / 2)],
                   fill=110)
        ridge = ridge.filter(ImageFilter.GaussianBlur(C * 0.012))
        body.alpha_composite(Image.composite(
            Image.new("RGBA", (C, C), STEEL_RIM + (255,)),
            Image.new("RGBA", (C, C), (0, 0, 0, 0)), ridge))
    else:
        body = Image.new("RGBA", (C, C), YELLOW + (255,))

    body.putalpha(mask)
    img.alpha_composite(body)

    # inner rim, inset and concentric with the outer edge
    rim = blank()
    ImageDraw.Draw(rim).polygon(heater_pts(cx, cy - h * 0.012, w * 0.80, h * 0.80),
                                outline=(STEEL_RIM if steel else INK),
                                width=int(C * 0.011))
    rim.putalpha(Image.composite(rim.split()[3], Image.new("L", (C, C), 0), mask))
    img.alpha_composite(rim)

def variant_d(steel=True):
    img = blank()
    backdrop(img)
    ow = int(C * 0.026)
    bang_outlined(img, C * 0.315, C * 0.475, C * 0.50, ow)
    knight_shield(img, C * 0.665, C * 0.485, C * 0.335, C * 0.425, ow, steel=steel)
    return img


if __name__ == "__main__":
    im = variant_d(steel=True).resize((N, N), Image.LANCZOS)
    im.save(os.path.join(OUT, "logo.png"))
    im.resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "logo-64.png"))
    print("wrote logo.png, logo-64.png")
