"""Procedural, tileable environment textures for VaranMod (numpy + PIL).

python tools/modelgen/gen_textures.py
Writes game/assets/textures/*.png
"""
import os
import math
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "game", "assets", "textures")
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(7)


# ------------------------------------------------------------------ tileable noise

def _hash2(ix, iy, seed):
    h = (ix * 374761393 + iy * 668265263 + seed * 2654435761) & 0xFFFFFFFF
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def value_noise(res, period, seed=0):
    y, x = np.mgrid[0:res, 0:res].astype(np.float64)
    fx = x / res * period
    fy = y / res * period
    ix = np.floor(fx).astype(np.int64)
    iy = np.floor(fy).astype(np.int64)
    tx = fx - ix
    ty = fy - iy
    tx = tx * tx * (3 - 2 * tx)
    ty = ty * ty * (3 - 2 * ty)
    a = _hash2(ix % period, iy % period, seed)
    b = _hash2((ix + 1) % period, iy % period, seed)
    c = _hash2(ix % period, (iy + 1) % period, seed)
    d = _hash2((ix + 1) % period, (iy + 1) % period, seed)
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


def fbm(res, period, octaves=5, seed=0, gain=0.5):
    s = np.zeros((res, res))
    a = 1.0
    tot = 0.0
    p = period
    for o in range(octaves):
        s += a * value_noise(res, p, seed + o * 31)
        tot += a
        a *= gain
        p *= 2
    return s / tot


def voronoi(res, period, seed=0, jitter=0.9):
    """F1, F2 and cell id, tileable."""
    y, x = np.mgrid[0:res, 0:res].astype(np.float64)
    fx = x / res * period
    fy = y / res * period
    ix = np.floor(fx).astype(np.int64)
    iy = np.floor(fy).astype(np.int64)
    F1 = np.full((res, res), 9.0)
    F2 = np.full((res, res), 9.0)
    ID = np.zeros((res, res))
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            cx = ix + dx
            cy = iy + dy
            wx = cx % period
            wy = cy % period
            px = cx + 0.5 + (_hash2(wx, wy, seed) - 0.5) * jitter
            py = cy + 0.5 + (_hash2(wx, wy, seed + 1) - 0.5) * jitter
            d = np.sqrt((fx - px) ** 2 + (fy - py) ** 2)
            closer = d < F1
            F2 = np.where(closer, F1, np.minimum(F2, d))
            ID = np.where(closer, _hash2(wx, wy, seed + 2), ID)
            F1 = np.where(closer, d, F1)
    return F1, F2, ID


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def normal_from_height(h, strength):
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    n = np.stack([-dx * strength, dy * strength, np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


def save(name, arr, alpha=None):
    arr = np.clip(arr, 0, 1)
    if alpha is not None:
        img = np.concatenate([arr, np.clip(alpha, 0, 1)[..., None]], -1)
        Image.fromarray((img * 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, name))
    else:
        Image.fromarray((arr * 255).astype(np.uint8), "RGB").save(os.path.join(OUT, name))
    print("wrote", name)


# ------------------------------------------------------------------ ground detail (neutral ~0.5 grey, tinted by vertex colour)

def ground():
    res = 1024
    grains = fbm(res, 128, 3, 1)
    mid = fbm(res, 16, 5, 2)
    F1, F2, ID = voronoi(res, 40, 3, 1.0)
    # irregular pebbles: cell shape distorted by noise, varied size, sparse
    distort = fbm(res, 96, 3, 17) * 0.22
    size = 0.18 + 0.28 * _hash2(np.floor(ID * 1000).astype(np.int64), 3, 4)
    peb = (ID > 0.8) & (F1 + distort < size)
    peb_h = np.where(peb, np.sqrt(np.clip(1 - ((F1 + distort) / np.maximum(size, 1e-3)) ** 2, 0, 1)), 0.0)
    F1b, F2b, IDb = voronoi(res, 160, 9)
    grit = (IDb > 0.8) * smooth(0.35, 0.0, F1b)
    cracks_F1, cracks_F2, _ = voronoi(res, 24, 5, 1.0)
    wob = fbm(res, 48, 3, 18) * 0.06
    crack = smooth(0.02, 0.0, cracks_F2 - cracks_F1 + wob) * smooth(0.55, 0.75, fbm(res, 6, 3, 6))
    h = grains * 0.25 + mid * 0.35 + peb_h * 0.8 + grit * 0.25 - crack * 0.2
    lum = 0.5 + (grains - 0.5) * 0.3 + (mid - 0.5) * 0.35 - crack * 0.08
    col = np.stack([lum, lum, lum], -1)
    # pebbles: pale quartz / dark ironstone
    pc = np.where(ID[..., None] > 0.9, np.array([0.72, 0.68, 0.62]), np.array([0.4, 0.3, 0.26]))
    col = np.where(peb[..., None], pc * (0.8 + 0.3 * grains[..., None]), col)
    col = np.where((grit > 0.3)[..., None], col * 1.25, col)
    save("ground_detail.png", col)
    save("ground_normal.png", normal_from_height(h, 5.0))


def rock():
    res = 1024
    y = np.mgrid[0:res, 0:res][0].astype(np.float64) / res
    warp = fbm(res, 6, 4, 11) * 0.6
    strata = 0.5 + 0.5 * np.sin((y * 14.0 + warp) * math.pi * 2)
    fine = fbm(res, 64, 4, 12)
    F1, F2, ID = voronoi(res, 5, 13, 1.0)
    crack = smooth(0.02, 0.0, F2 - F1 + fbm(res, 32, 3, 19) * 0.05) * smooth(0.4, 0.7, fbm(res, 4, 2, 20))
    pits = smooth(0.12, 0.0, voronoi(res, 90, 14)[0]) * (voronoi(res, 90, 14)[2] > 0.8)
    h = strata * 0.3 + fine * 0.5 - crack * 0.4 - pits * 0.3 + (ID - 0.5) * 0.1
    lum = 0.45 + strata * 0.12 + (fine - 0.5) * 0.4 - crack * 0.15 + (ID - 0.5) * 0.04
    tint = np.stack([lum * 1.0, lum * 0.93, lum * 0.88], -1)
    # desert varnish streaks
    streak = smooth(0.55, 0.8, fbm(res, 12, 3, 15)) * smooth(0.3, 0.9, value_noise(res, 40, 16))
    tint = tint * (1 - 0.35 * streak[..., None])
    save("rock_detail.png", tint)
    save("rock_normal.png", normal_from_height(h, 6.0))


def bark():
    res = 512
    x = np.mgrid[0:res, 0:res][1].astype(np.float64) / res
    # smooth ghost-gum bark: pale with pink/grey decorticating patches
    p1 = fbm(res, 5, 5, 21)
    p2 = fbm(res, 12, 4, 22)
    patch = smooth(0.52, 0.56, p1)
    base = np.array([0.9, 0.88, 0.82])
    pink = np.array([0.8, 0.66, 0.6])
    grey = np.array([0.62, 0.62, 0.6])
    col = base * (0.92 + 0.12 * p2[..., None])
    col = np.where(patch[..., None] > 0.5, pink * (0.9 + 0.15 * p2[..., None]), col)
    col = np.where((smooth(0.62, 0.66, p2) > 0.5)[..., None], grey, col)
    edge = smooth(0.03, 0.0, np.abs(p1 - 0.54))
    h = patch * 0.4 + p2 * 0.3 - edge * 0.3
    save("bark_gum.png", col * (1 - 0.25 * edge[..., None]))
    save("bark_gum_normal.png", normal_from_height(h, 3.0))
    # rough stringybark: vertical fibres, deep furrows
    fib = value_noise(res, 64, 23)
    fib = np.roll(fib, 0, 0)
    # stretch vertically: sample columns
    v = np.stack([value_noise(res, 48, 24 + k) for k in range(1)], 0)[0]
    stretched = np.repeat(v[:, ::8], 8, axis=1)[:res, :res]
    cols = fbm(res, 32, 3, 25)
    furrow = smooth(0.35, 0.6, np.sin(x * math.pi * 2 * 14 + cols * 5.0) * 0.5 + 0.5)
    h2 = furrow * 0.6 + stretched.T * 0.3 + fbm(res, 96, 3, 26) * 0.2
    c2 = np.array([0.38, 0.3, 0.24]) * (0.6 + 0.5 * furrow[..., None]) * (0.85 + 0.25 * fbm(res, 20, 3, 27)[..., None])
    save("bark_stringy.png", c2)
    save("bark_stringy_normal.png", normal_from_height(h2, 6.0))


def _leaf(canvas, alpha, cx, cy, ang, length, width, col, curve):
    res = canvas.shape[0]
    x0 = int(max(cx - length - 2, 0))
    x1 = int(min(cx + length + 2, res - 1))
    y0 = int(max(cy - length - 2, 0))
    y1 = int(min(cy + length + 2, res - 1))
    if x1 <= x0 or y1 <= y0:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    dx = xx - cx
    dy = yy - cy
    ca, sa = math.cos(ang), math.sin(ang)
    u = dx * ca + dy * sa          # along leaf 0..length
    v = -dx * sa + dy * ca
    t = u / length
    v = v - curve * length * t * t   # sickle curve
    wprof = width * np.sin(np.clip(t, 0, 1) * math.pi) ** 0.8 * (1 - 0.3 * t)
    inside = (t >= 0) & (t <= 1) & (np.abs(v) < wprof)
    mid = np.abs(v) < np.maximum(wprof * 0.12, 0.5)
    shade = 0.85 + 0.25 * (v / np.maximum(wprof, 1e-3)) * 0.5
    c = col[None, None, :] * shade[..., None]
    c = np.where(mid[..., None], c * 1.18, c)
    region = canvas[y0:y1, x0:x1]
    region[inside] = c[inside]
    alpha[y0:y1, x0:x1][inside] = 1.0


def leaves():
    """Drooping eucalyptus leaf clusters on transparent background."""
    res = 512
    canvas = np.zeros((res, res, 3))
    alpha = np.zeros((res, res))
    greens = [np.array([0.36, 0.43, 0.3]), np.array([0.44, 0.5, 0.36]), np.array([0.3, 0.37, 0.27]), np.array([0.5, 0.52, 0.38])]
    # twigs
    for k in range(9):
        x0 = rng.uniform(40, res - 40)
        y0 = rng.uniform(10, 60)
        pts = [(x0, y0)]
        for s in range(8):
            px, py = pts[-1]
            pts.append((px + rng.uniform(-18, 18), py + rng.uniform(30, 55)))
        for (ax, ay), (bx, by) in zip(pts, pts[1:]):
            n = 30
            for i in range(n):
                t = i / n
                cx = int(ax + (bx - ax) * t)
                cy = int(ay + (by - ay) * t)
                if 0 <= cx < res and 0 <= cy < res:
                    canvas[max(cy - 1, 0):cy + 1, max(cx - 1, 0):cx + 1] = [0.42, 0.32, 0.26]
                    alpha[max(cy - 1, 0):cy + 1, max(cx - 1, 0):cx + 1] = 1.0
            for j in range(3):
                t = rng.uniform(0, 1)
                lx = ax + (bx - ax) * t
                ly = ay + (by - ay) * t
                ang = math.pi * 0.5 + rng.uniform(-0.9, 0.9)
                _leaf(canvas, alpha, lx, ly, ang, rng.uniform(45, 80), rng.uniform(6, 10), greens[rng.integers(0, 4)] * rng.uniform(0.85, 1.1), rng.uniform(-0.25, 0.25))
    save("leaves_euc.png", canvas, alpha)
    # small acacia / saltbush leaves (bushes)
    canvas = np.zeros((res, res, 3))
    alpha = np.zeros((res, res))
    bgreens = [np.array([0.42, 0.46, 0.3]), np.array([0.5, 0.52, 0.36]), np.array([0.55, 0.56, 0.44])]
    for k in range(600):
        _leaf(canvas, alpha, rng.uniform(0, res), rng.uniform(0, res), rng.uniform(0, math.tau), rng.uniform(14, 30), rng.uniform(4, 7), bgreens[rng.integers(0, 3)] * rng.uniform(0.8, 1.1), rng.uniform(-0.2, 0.2))
    save("leaves_bush.png", canvas, alpha)


def grass():
    """Dry tussock grass blades card (RGBA)."""
    res = 512
    canvas = np.zeros((res, res, 3))
    alpha = np.zeros((res, res))
    for k in range(140):
        bx = rng.uniform(20, res - 20)
        h = rng.uniform(0.45, 0.98) * res
        lean = rng.uniform(-0.35, 0.35)
        w = rng.uniform(2.0, 4.5)
        tip_c = np.array([0.88, 0.78, 0.5]) * rng.uniform(0.85, 1.05)
        base_c = np.array([0.5, 0.44, 0.26]) if rng.random() < 0.7 else np.array([0.42, 0.46, 0.25])
        n = int(h)
        for i in range(n):
            t = i / n
            y = res - 1 - i
            x = bx + lean * i + lean * 0.4 * i * t
            ww = w * (1 - t) + 0.4
            x0 = int(max(x - ww, 0))
            x1 = int(min(x + ww, res - 1))
            if x1 < x0 or y < 0:
                continue
            c = base_c * (1 - t) + tip_c * t
            canvas[y, x0:x1 + 1] = c * (0.9 + 0.2 * rng.random())
            alpha[y, x0:x1 + 1] = 1.0
    save("grass_card.png", canvas, alpha)


if __name__ == "__main__":
    ground()
    rock()
    bark()
    leaves()
    grass()
