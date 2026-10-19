"""Stabilis logo concepts in gold on charcoal granite: 1 carved Roman S, 2 column, 3 temple front, 4 Roman gold coin
(the shipped icon). Usage: logos.py OUTDIR GRANITE.png FONT.ttf — see make-icon.sh."""
import sys, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT, GRANITE, FONT = sys.argv[1], sys.argv[2], sys.argv[3]
N = 2048  # supersampled; saved at 1024

_fy = np.fft.fftfreq(N)[:, None].astype(np.float32)
_fx = np.fft.rfftfreq(N)[None, :].astype(np.float32)
def blur(a, r):
    if r <= 0: return a
    k = np.exp(-2 * (np.pi ** 2) * (r ** 2) * (_fx ** 2 + _fy ** 2))
    return np.fft.irfft2(np.fft.rfft2(a) * k, s=a.shape).astype(np.float32)

def smooth(e0, e1, v):
    t = np.clip((v - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)

def granite_bg():
    g = np.asarray(Image.open(GRANITE).convert("RGB").resize((N, N), Image.LANCZOS), dtype=np.float32) / 255
    g = g ** 1.9  # back to linear-ish
    ys, xs = np.mgrid[0:N, 0:N] / N
    vign = 1 - 0.55 * np.clip(np.hypot(xs - 0.5, ys - 0.45) / 0.75, 0, 1) ** 1.6
    return g * 0.62 * vign[..., None]

def mask_from(draw_fn):
    im = Image.new("L", (N, N), 0); draw_fn(ImageDraw.Draw(im)); return np.asarray(im, dtype=np.float32) / 255

L = np.array([-0.5, -0.65, 0.58]); L /= np.linalg.norm(L)
H = L + np.array([0, 0, 1.0]); H /= np.linalg.norm(H)

def normals(h):
    gy, gx = np.gradient(h); nx, ny, nz = -gx, -gy, np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz); return nx / ln, ny / ln, nz / ln

def gold_shade(h, flakes=None):
    nx, ny, nz = normals(h)
    ndl = np.clip(nx * L[0] + ny * L[1] + nz * L[2], 0, 1)
    ndh = np.clip(nx * H[0] + ny * H[1] + nz * H[2], 0, 1)
    alb = np.array([1.0, 0.74, 0.30])
    up = np.clip(-ny * 1.6 + nz * 0.45, 0, 1)[..., None]
    env = np.array([0.14, 0.09, 0.03]) * (1 - up) + np.array([1.15, 0.98, 0.70]) * up
    c = alb * env * (0.40 + 0.85 * ndl[..., None])
    c = c + (ndh ** 60)[..., None] * np.array([1.0, 0.95, 0.80]) * 2.2 + (ndh ** 12)[..., None] * alb * 0.35
    if flakes is not None: c = c * (0.9 + 0.2 * flakes[..., None])
    return c

def drop_shadow(bg, m, dx=18, dy=26, r=22, k=0.7):
    s = np.roll(np.roll(blur(m, r), dy, 0), dx, 1)
    return bg * (1 - k * np.clip(s, 0, 1))[..., None]

def emboss_height(m, bevel):
    """Raised metal: flat top with rounded bevel at the edges."""
    return smooth(0.0, 1.0, blur(m, bevel)) * bevel * 1.2

def save(img, name):
    img = img / (1 + img * 0.3)
    img = np.clip(img, 0, 1) ** (1 / 2.0)
    Image.fromarray((img * 255 + 0.5).astype(np.uint8), "RGB").resize((1024, 1024), Image.LANCZOS).save(f"{OUT}/{name}.png")

rng = np.random.default_rng(5)
flakes = np.asarray(Image.fromarray(rng.random((256, 256)).astype(np.float32), "F").resize((N, N), Image.BICUBIC))

# ---------------------------------------------------------------- 1. Carved, gilded Roman S
font = ImageFont.truetype(FONT, 1500)
def draw_S(d):
    bb = d.textbbox((0, 0), "S", font=font); w, h = bb[2] - bb[0], bb[3] - bb[1]
    d.text(((N - w) / 2 - bb[0], (N - h) / 2 - bb[1] - 20), "S", font=font, fill=255)
mS = mask_from(draw_S)
bg = granite_bg()
# V-cut: the letter is incised, deepest along its spine; light rakes across the two walls of each stroke.
depth = blur(mS, 26) * mS
hS = -depth * 260
gold = gold_shade(hS, flakes)
# Inner shadow under the upper edge of the cut, and a lit lower lip on the stone.
lip = np.clip(blur(mS, 6) - mS, 0, 1)
img = bg * (1 - 0.6 * np.roll(lip, -6, 0))[..., None] + np.roll(lip, 6, 0)[..., None] * 0.10
img = img * (1 - mS[..., None]) + gold * mS[..., None]
save(img, "1-carved-S")

# ---------------------------------------------------------------- 2. Gold Doric column on a plinth
def draw_column(d):
    cx = N / 2
    d.rectangle([cx - 460, 1690, cx + 460, 1790], fill=255)            # plinth
    d.rectangle([cx - 360, 1600, cx + 360, 1690], fill=255)            # base
    d.polygon([(cx - 230, 1600), (cx + 230, 1600), (cx + 200, 520), (cx - 200, 520)], fill=255)  # tapered shaft
    d.rectangle([cx - 380, 280, cx + 380, 390], fill=255)              # abacus
    d.polygon([(cx - 320, 390), (cx + 320, 390), (cx + 215, 520), (cx - 215, 520)], fill=255)    # echinus
mC = mask_from(draw_column)
# Flutes: vertical grooves on the shaft.
ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
shaft = (ys > 520) & (ys < 1600)
half = 230 - (1600 - ys) / (1600 - 520) * 30
u = np.clip((xs - N / 2) / np.maximum(half, 1), -1, 1)
flute = (0.5 + 0.5 * np.cos(u * math.pi * 6)) * shaft
hC = emboss_height(mC, 10) * 3 + np.sqrt(np.clip(1 - u ** 2, 0, 1)) * 110 * shaft - flute * 16
hC = hC * mC
bg = drop_shadow(granite_bg(), mC)
img = bg * (1 - mC[..., None]) + gold_shade(hC, flakes) * mC[..., None]
save(img, "2-column")

# ---------------------------------------------------------------- 3. Temple front: pediment, four columns, steps
def draw_temple(d):
    cx = N / 2
    d.polygon([(cx - 760, 700), (cx, 330), (cx + 760, 700)], fill=255)          # pediment
    d.rectangle([cx - 780, 720, cx + 780, 830], fill=255)                          # entablature
    for i in range(4):
        x = cx - 570 + i * 380
        d.rectangle([x - 95, 870, x + 95, 1500], fill=255)                         # columns
        d.rectangle([x - 130, 840, x + 130, 880], fill=255)                        # capitals
    d.rectangle([cx - 820, 1520, cx + 820, 1600], fill=255)                        # steps
    d.rectangle([cx - 900, 1620, cx + 900, 1710], fill=255)
mT = mask_from(draw_temple)
# Cut a recessed tympanum inside the pediment.
tym = mask_from(lambda d: d.polygon([(N/2 - 600, 670), (N/2, 420), (N/2 + 600, 670)], fill=255))
colmask = np.zeros_like(mT)
for i in range(4):
    x = N / 2 - 570 + i * 380
    sel = (ys > 880) & (ys < 1500) & (np.abs(xs - x) < 95)
    uu = np.clip((xs - x) / 95, -1, 1)
    colmask = np.maximum(colmask, sel * np.sqrt(np.clip(1 - uu ** 2, 0, 1)))
hT = (emboss_height(mT, 8) * 3 + colmask * 60 - tym * 22) * mT
bg = drop_shadow(granite_bg(), mT)
img = bg * (1 - mT[..., None]) + gold_shade(hT, flakes) * mT[..., None]
save(img, "3-temple")

# ---------------------------------------------------------------- 4. Roman gold coin (solidus): laurel wreath around a Roman S
R = 760
rr = np.hypot(xs - N / 2, ys - N / 2)
disc = smooth(R + 2, R - 2, rr)
dome = np.sqrt(np.clip(1 - (rr / (R * 1.6)) ** 2, 0, 1)) * 120
rim = smooth(R - 70, R - 50, rr) * disc
beads = np.zeros_like(rr)
for k in range(72):
    a = 2 * math.pi * k / 72; bx, by = N / 2 + (R - 105) * math.cos(a), N / 2 + (R - 105) * math.sin(a)
    beads = np.maximum(beads, smooth(15, 9, np.hypot(xs - bx, ys - by)))
def leaf(d, x, y, ang, length, width):
    pts = []
    for k in range(24):
        t = k / 23 * 2 * math.pi
        lx, ly = math.cos(t) * length / 2, math.sin(t) * width / 2 * (1 - 0.35 * math.cos(t))
        pts.append((x + lx * math.cos(ang) - ly * math.sin(ang), y + lx * math.sin(ang) + ly * math.cos(ang)))
    d.polygon(pts, fill=255)
def draw_wreath(d):
    cx, cy, r = N / 2, N / 2 + 10, 515
    for side in (-1, 1):
        for k in range(10):
            phi = math.radians(28 + k * 13.5)            # from near the bottom up the side
            x, y = cx + side * r * math.sin(phi), cy + r * math.cos(phi)
            tang = math.atan2(-math.sin(phi), side * math.cos(phi))   # direction of travel up the arc
            for off, tilt in ((-30, -0.55), (30, 0.55)):            # a leaf either side of the stem
                ox, oy = off * math.cos(tang + math.pi / 2), off * math.sin(tang + math.pi / 2)
                leaf(d, x + ox, y + oy, tang + side * tilt, 92, 34)
        # the stem
        for k in range(60):
            phi = math.radians(22 + k * 2.4)
            x, y = cx + side * r * math.sin(phi), cy + r * math.cos(phi)
            d.ellipse([x - 7, y - 7, x + 7, y + 7], fill=255)
mW = mask_from(draw_wreath)
font2 = ImageFont.truetype(FONT, 820)
def draw_S2(d):
    bb = d.textbbox((0, 0), "S", font=font2); w, h = bb[2] - bb[0], bb[3] - bb[1]
    d.text(((N - w) / 2 - bb[0], (N - h) / 2 - bb[1] - 10), "S", font=font2, fill=255)
mS2 = mask_from(draw_S2)
relief = np.clip(mW + mS2, 0, 1)
hK = (dome + rim * 30 + beads * 22 + emboss_height(relief, 7) * 4) * disc
bg = drop_shadow(granite_bg(), disc, dx=20, dy=30, r=30, k=0.75)
coin = gold_shade(hK, flakes) * (0.82 + 0.18 * (1 - relief))[..., None]
img = bg * (1 - disc[..., None]) + coin * disc[..., None]
save(img, "4-coin")
print("ok")
