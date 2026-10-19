"""Stabilis app icon source: polished charcoal granite with a gold vein, rendered procedurally (numpy + Pillow).
Writes face.png (the polished surface, square) and edge.png (a slab front edge, unused by the icon).
Usage: python slab.py OUTDIR 3   — then see make-icon.sh. Seed 3 is the shipped icon."""
import sys
import numpy as np
from PIL import Image

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 3
N = 1600


def grid(w, h):
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    return xs / w, ys / h


def layer(cells_x, cells_y, w, h, rng):
    g = rng.random((cells_y, cells_x)).astype(np.float32)
    return np.asarray(Image.fromarray(g, mode="F").resize((w, h), Image.BICUBIC), dtype=np.float32)


def fbm(base, octaves, w, h, seed, gain=0.5, aspect=1.0):
    rng = np.random.default_rng(seed)
    total, amp, norm, cells = 0.0, 1.0, 0.0, base
    for _ in range(octaves):
        total = total + amp * layer(max(2, int(cells)), max(2, int(cells * aspect)), w, h, rng)
        norm += amp; amp *= gain; cells *= 2
    return total / norm


def smooth(e0, e1, v):
    t = np.clip((v - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def granite(w, h, seed, aspect=1.0):
    """Charcoal granite: near-black ground, grey and white feldspar/quartz crystals, a few warm grains."""
    f = lambda base, s, oct=2, g=0.35: fbm(base, oct, w, h, seed + s, gain=g, aspect=aspect)
    ground = 0.085 + (f(6, 1, 3, 0.5) - 0.5) * 0.04
    alb = np.stack([ground, ground * 1.02, ground * 1.06], -1)
    grey = np.maximum(smooth(0.66, 0.70, f(210, 2)), smooth(0.70, 0.73, f(110, 3)) * 0.9)
    white = np.maximum(smooth(0.70, 0.73, f(260, 4)), smooth(0.73, 0.76, f(130, 5)))
    warm = smooth(0.73, 0.76, f(170, 6))
    alb = alb * (1 - grey[..., None]) + grey[..., None] * np.array([0.30, 0.31, 0.32])
    alb = alb * (1 - white[..., None]) + white[..., None] * np.array([0.62, 0.62, 0.60])
    alb = alb * (1 - warm[..., None] * 0.7) + warm[..., None] * 0.7 * np.array([0.36, 0.25, 0.20])
    return alb


def vein_field(x, y, path, width, seed, w, h, aspect=1.0):
    """Distance-based vein mask along a polyline, with wandering edges."""
    px, py = path
    best = np.full(x.shape, 9.0, dtype=np.float32)
    along = np.zeros_like(best)
    for i in range(len(px) - 1):
        ax_, ay_, bx, by = px[i], py[i], px[i + 1], py[i + 1]
        dx, dy = bx - ax_, by - ay_
        t = np.clip(((x - ax_) * dx + (y - ay_) * dy) / (dx * dx + dy * dy), 0, 1)
        d = np.hypot(x - (ax_ + t * dx), y - (ay_ + t * dy))
        closer = d < best
        best = np.where(closer, d, best); along = np.where(closer, (i + t) / (len(px) - 1), along)
    wobble = (fbm(14, 4, w, h, seed + 20, aspect=aspect) - 0.5) * width * 1.6
    taper = 0.55 + 0.9 * fbm(3, 2, w, h, seed + 21, aspect=aspect)
    return smooth(width * taper, width * taper * 0.55, best + wobble), best


rng_seed = SEED * 100
# --------------------------------------------------------------------------- face
x, y = grid(N, N)
alb = granite(N, N, rng_seed)
rng = np.random.default_rng(SEED)
# Main vein: enters at the front edge (bottom, u≈0.30) and runs up and across to the back right.
pts_x = np.array([0.30, 0.33, 0.38, 0.44, 0.50, 0.56, 0.63, 0.70, 0.78, 0.88, 1.05])
pts_y = np.array([1.02, 0.90, 0.79, 0.70, 0.60, 0.51, 0.44, 0.36, 0.27, 0.17, 0.05])
pts_x[1:-1] += rng.normal(0, 0.018, 9); pts_y[1:-1] += rng.normal(0, 0.018, 9)
main, _ = vein_field(x, y, (pts_x, pts_y), 0.022, rng_seed, N, N)
# Thin branches.
def wander(ax_, ay_, bx, by, n=14, amp=0.010):
    t = np.linspace(0, 1, n)
    jx, jy = rng.normal(0, amp, n), rng.normal(0, amp, n); jx[[0, -1]] = 0; jy[[0, -1]] = 0
    return ax_ + (bx - ax_) * t + jx, ay_ + (by - ay_) * t + jy


b1, _ = vein_field(x, y, wander(pts_x[2], pts_y[2], -0.05, 0.42), 0.0055, rng_seed + 1, N, N)
b2, _ = vein_field(x, y, wander(pts_x[4], pts_y[4], 1.05, 0.58), 0.0045, rng_seed + 2, N, N)
vein = np.clip(main + b1 * 0.9 + b2 * 0.85, 0, 1)

# Gold: polished metal. Brightness varies with flakes and a soft directional streak, like light moving across it.
flakes = fbm(60, 3, N, N, rng_seed + 30)
streak = 0.5 + 0.5 * np.sin((x * 0.8 - y * 1.3) * 9 + fbm(5, 2, N, N, rng_seed + 31) * 4)
gold = np.array([0.80, 0.56, 0.17])[None, None, :] * (0.65 + 0.55 * flakes[..., None]) * (0.75 + 0.45 * streak[..., None])
gold = gold + (smooth(0.72, 0.85, flakes) * smooth(0.6, 1.0, streak))[..., None] * np.array([0.55, 0.45, 0.25])
# A darker oxidised rim where gold meets stone.
rim = np.clip(vein * (1 - vein) * 4, 0, 1)
face = alb * (1 - vein[..., None]) + gold * vein[..., None]
face = face * (1 - rim[..., None] * 0.35)
# Polish: a broad soft reflection band across the surface, and a gentle falloff toward the back.
sheen = np.exp(-((x * 0.9 + y * 0.6 - 0.62) / 0.16) ** 2) * 0.10
face = face + sheen[..., None] * np.array([0.85, 0.90, 0.92])
face = face * (0.86 + 0.14 * y)[..., None]
face = np.clip(face, 0, 1) ** (1 / 1.9)
Image.fromarray((face * 255 + 0.5).astype(np.uint8), "RGB").save(f"{OUT}/face.png")

# --------------------------------------------------------------------------- edge (front face of the slab)
EW, EH = N, 260
ex, ey = grid(EW, EH)
ealb = granite(EW, EH, rng_seed + 7, aspect=EH / EW * 6)
# Honed (not polished) edge: a little lighter and flatter; darker toward the bottom.
ealb = ealb * 1.15 * (1 - 0.35 * ey)[..., None]
# The vein continues down the edge from where it meets the front of the face.
# Line it up with where the face's vein actually meets the front edge, at the same width.
row = main[-3]
cols = np.nonzero(row > 0.5)[0]
v0 = (cols.mean() / N) if cols.size else 0.30
hw = max(0.004, (cols.size / N) / 2) if cols.size else 0.012
vx = v0 + (fbm(4, 3, EW, EH, rng_seed + 40) - 0.5) * 0.012 + ey * 0.01
evein = smooth(hw, hw * 0.6, np.abs(ex - vx))
egold = np.array([0.62, 0.43, 0.13]) * (0.7 + 0.5 * fbm(40, 3, EW, EH, rng_seed + 41))[..., None]
edge = ealb * (1 - evein[..., None]) + egold * evein[..., None]
edge = np.clip(edge, 0, 1) ** (1 / 1.9)
Image.fromarray((edge * 255 + 0.5).astype(np.uint8), "RGB").save(f"{OUT}/edge.png")
print("ok")
