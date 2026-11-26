"""Generates the game's starter PBR textures and sound effects.

Run from the project root:  python3 tools/gen_assets.py
Outputs to assets/textures and assets/audio. Replace any file with hand-made
art later; materials in assets/materials reference these paths.
"""
import os, math, wave, struct
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

rng = np.random.default_rng(7)
TEX = 'assets/textures'
AUD = 'assets/audio'
os.makedirs(TEX, exist_ok=True)
os.makedirs(AUD, exist_ok=True)

# ---------------- helpers ----------------
def blur_wrap(a, r):
    if r <= 0: return a
    out = a.copy()
    for _ in range(2):
        acc = np.zeros_like(out)
        for d in range(-r, r + 1):
            acc += np.roll(out, d, axis=0)
        out = acc / (2 * r + 1)
        acc = np.zeros_like(out)
        for d in range(-r, r + 1):
            acc += np.roll(out, d, axis=1)
        out = acc / (2 * r + 1)
    return out

def fbm(h, w, octaves=5, base=4):
    out = np.zeros((h, w))
    amp = 1.0
    for o in range(octaves):
        n = rng.random((h, w))
        n = blur_wrap(n, max(1, int(min(h, w) / (base * 2 ** o) / 2)))
        n = (n - n.min()) / (np.ptp(n) + 1e-9)
        out += n * amp
        amp *= 0.5
    return (out - out.min()) / (np.ptp(out) + 1e-9)

def normal_from_height(hm, strength=2.0):
    dx = (np.roll(hm, -1, axis=1) - np.roll(hm, 1, axis=1)) * 0.5
    dy = (np.roll(hm, -1, axis=0) - np.roll(hm, 1, axis=0)) * 0.5
    nx, ny, nz = -dx * strength, dy * strength, np.ones_like(hm)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx / l, ny / l, nz / l], axis=-1)
    return Image.fromarray(((n * 0.5 + 0.5) * 255).clip(0, 255).astype(np.uint8), 'RGB')

def save_rgb(arr, name):
    Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGB').save(f'{TEX}/{name}.png', optimize=True)

def orm(ao, rough, metal, name):
    a = np.stack([ao, rough, metal], axis=-1) * 255
    save_rgb(a, name)

def tint_noise(h, w, base, amt, scale=5):
    n = fbm(h, w, 4, scale) - 0.5
    return np.clip(np.array(base, float)[None, None, :] * (1 + n[..., None] * amt), 0, 255)

def save_set(name, albedo, height, rough, metal=None, nstrength=3.0, ao_amt=0.6):
    save_rgb(albedo, f'{name}_albedo')
    normal_from_height(height, nstrength).save(f'{TEX}/{name}_normal.png', optimize=True)
    ao = 1 - ao_amt * (blur_wrap(height, 3) - height).clip(0, 1) * 4
    orm(ao.clip(0, 1), rough, metal if metal is not None else np.zeros_like(rough), f'{name}_orm')

# ---------------- facades (one tile = 4 m wide x 3.4 m tall) ----------------
FW, FH = 512, 448
def window_facade(name, wall_rgb, wall_rough, kind):
    h = np.zeros((FH, FW)) + 0.6
    alb = tint_noise(FH, FW, wall_rgb, 0.08, 6)
    rough = np.zeros((FH, FW)) + wall_rough
    metal = np.zeros((FH, FW))
    grain = fbm(FH, FW, 5, 24)
    h += grain * 0.04
    if kind == 'brick':
        for r in range(0, FH, 16):
            off = 16 if (r // 16) % 2 else 0
            for c in range(-32, FW + 32, 32):
                x0, x1 = c + off + 1, c + off + 31
                col = np.array([165 + rng.integers(-18, 18), 82 + rng.integers(-12, 12), 60 + rng.integers(-10, 10)])
                xa, xb = max(0, x0), min(FW, x1)
                if xb > xa:
                    alb[r + 1:r + 15, xa:xb] = col
                    h[r + 1:r + 15, xa:xb] = 0.7
        alb[(np.arange(FH) % 16) == 0, :] = [205, 198, 186]
    if kind in ('stucco', 'brick'):
        # one tall window per bay: frame, glass, mullions, sill
        x0, x1, y0, y1 = 112, 400, 56, 352
        alb[y0 - 10:y1 + 10, x0 - 10:x1 + 10] = [236, 232, 224]
        h[y0 - 10:y1 + 10, x0 - 10:x1 + 10] = 0.75
        glass(alb, h, rough, metal, x0, y0, x1, y1)
        for gx in (x0 + (x1 - x0) // 2 - 5,):
            alb[y0:y1, gx:gx + 10] = [238, 234, 226]; h[y0:y1, gx:gx + 10] = 0.65; rough[y0:y1, gx:gx + 10] = 0.5
        alb[y0 + 105:y0 + 113, x0:x1] = [238, 234, 226]; h[y0 + 105:y0 + 113, x0:x1] = 0.65
        alb[y1 + 6:y1 + 26, x0 - 22:x1 + 22] = [208, 202, 192]; h[y1 + 6:y1 + 26, x0 - 22:x1 + 22] = 0.9
        alb[FH - 14:FH, :] = alb[FH - 14:FH, :] * 0.88; h[FH - 14:FH, :] = 0.66
    elif kind == 'office':
        y0, y1 = 70, 340
        glass(alb, h, rough, metal, 0, y0, FW, y1, dark=(40, 62, 82), light=(126, 156, 178))
        for i in range(4):
            xm = i * 128
            alb[y0:y1, xm:xm + 8] = [196, 200, 206]; h[y0:y1, xm:xm + 8] = 0.7; rough[y0:y1, xm:xm + 8] = 0.35; metal[y0:y1, xm:xm + 8] = 0.8
        alb[y1:y1 + 10, :] = [180, 184, 190]; h[y1:y1 + 10, :] = 0.7
        alb[y0 - 8:y0, :] = [180, 184, 190]
    elif kind == 'glass':
        glass(alb, h, rough, metal, 0, 0, FW, FH, dark=(70, 108, 136), light=(150, 186, 206))
        for i in range(4):
            xm = i * 128
            alb[:, xm:xm + 6] = [52, 72, 88]; h[:, xm:xm + 6] = 0.62; metal[:, xm:xm + 6] = 0.9; rough[:, xm:xm + 6] = 0.3
        alb[FH - 16:FH, :] = [52, 72, 88]; h[FH - 16:FH, :] = 0.62; metal[FH - 16:FH, :] = 0.9
        alb[212:216, :] = [60, 80, 96]
        for i in range(4):
            for j in range(2):
                v = rng.random() * 18
                xs, ys = i * 128 + 6, j * 216
                alb[ys:ys + 212, xs:xs + 122] += v
    save_set(name, alb, h, rough, metal, 4.0)

def glass(alb, h, rough, metal, x0, y0, x1, y1, dark=(30, 48, 64), light=(98, 132, 158)):
    hh = y1 - y0
    t = np.linspace(0, 1, hh)[:, None]
    g = np.array(dark)[None, None, :] * (1 - t[..., None]) + np.array(light)[None, None, :] * t[..., None]
    alb[y0:y1, x0:x1] = g
    # diagonal sky reflection streak
    yy, xx = np.mgrid[y0:y1, x0:x1]
    band = ((xx - x0) * 0.55 + (yy - y0) * 0.9) % 420
    alb[y0:y1, x0:x1] += ((band > 120) & (band < 175))[..., None] * 22
    h[y0:y1, x0:x1] = 0.4
    rough[y0:y1, x0:x1] = 0.06
    metal[y0:y1, x0:x1] = 0.15

window_facade('facade_stucco', (244, 240, 233), 0.88, 'stucco')
window_facade('facade_brick', (200, 190, 180), 0.9, 'brick')
window_facade('facade_office', (226, 228, 231), 0.7, 'office')
window_facade('facade_glass', (200, 210, 220), 0.2, 'glass')

# ground-floor shopfront (4 m x 4.2 m)
SH = 536
alb = tint_noise(SH, FW, (242, 239, 233), 0.06, 6)
h = np.zeros((SH, FW)) + 0.6
rough = np.zeros((SH, FW)) + 0.8
metal = np.zeros((SH, FW))
alb[0:110, :] = [240, 236, 228]; h[100:112, :] = 0.8
alb[472:, :] = [46, 50, 56]; h[472:, :] = 0.7; rough[472:, :] = 0.6
alb[126:472, 14:498] = [232, 228, 220]; h[126:472, 14:498] = 0.72
glass(alb, h, rough, metal, 30, 140, 482, 468, dark=(26, 40, 54), light=(88, 118, 140))
alb[140:468, 250:262] = [230, 226, 218]; h[140:468, 250:262] = 0.7
alb[214:222, 30:482] = [230, 226, 218]
alb[250:460, 40:220] += np.array([28, 20, 4])  # warm interior glow
save_set('shopfront', alb, h, rough, metal, 4.0)

# ---------------- ground materials ----------------
S = 512
def asphalt():
    n = fbm(S, S, 6, 32)
    alb = np.zeros((S, S, 3)) + 62 + (n[..., None] - 0.5) * 34
    speck = rng.random((S, S)) > 0.985
    alb[speck] += 40
    cracks = np.zeros((S, S))
    for _ in range(10):
        x, y = rng.integers(0, S, 2)
        ang = rng.random() * 6.28
        for k in range(120):
            ang += (rng.random() - 0.5) * 0.6
            x = int(x + math.cos(ang) * 2) % S; y = int(y + math.sin(ang) * 2) % S
            cracks[y, x] = 1
    cracks = blur_wrap(cracks, 1) > 0.12
    alb[cracks] *= 0.55
    hgt = n * 0.4 + rng.random((S, S)) * 0.25 - cracks * 0.5
    save_set('asphalt', alb, hgt, np.zeros((S, S)) + 0.92 - n * 0.1, None, 3.0)
asphalt()

def tiles(name, base, tile_px, grout, amt=0.08, rough=0.85, gstrength=4.0):
    n = fbm(S, S, 5, 8)
    alb = tint_noise(S, S, base, amt, 8)
    hgt = 0.6 + n * 0.08
    yy, xx = np.mgrid[0:S, 0:S]
    g = ((xx % tile_px) < 4) | ((yy % tile_px) < 4)
    alb[g] = grout
    hgt[g] = 0.3
    save_set(name, alb, hgt, np.zeros((S, S)) + rough, None, gstrength)
tiles('sidewalk', (186, 182, 174), 171, (140, 136, 130))
tiles('checker_floor', (240, 241, 242), 128, (190, 192, 195), 0.03, 0.35)
# checker colouring
im = np.array(Image.open(f'{TEX}/checker_floor_albedo.png')).astype(float)
yy, xx = np.mgrid[0:S, 0:S]
im[((xx // 128) + (yy // 128)) % 2 == 1] *= 0.86
save_rgb(im, 'checker_floor_albedo')

def gravel():
    n = fbm(S, S, 6, 48)
    alb = np.zeros((S, S, 3)) + 128 + (n[..., None] - 0.5) * 60
    pebbles = blur_wrap((rng.random((S, S)) > 0.92).astype(float), 1)
    save_set('roof_gravel', alb, n * 0.3 + pebbles, np.zeros((S, S)) + 0.95, None, 2.5)
gravel()

def sand():
    n = fbm(S, S, 6, 6)
    ripple = np.sin((np.mgrid[0:S, 0:S][0] / S * 2 * math.pi * 9) + n * 6) * 0.5 + 0.5
    alb = np.zeros((S, S, 3)) + np.array([232, 214, 166]) * (0.92 + n[..., None] * 0.12)
    save_set('sand', alb, ripple * 0.3 + rng.random((S, S)) * 0.15, np.zeros((S, S)) + 0.95, None, 1.5)
sand()

def grass():
    n = fbm(S, S, 6, 10)
    blades = rng.random((S, S))
    alb = np.zeros((S, S, 3))
    alb[..., 0] = 70 + n * 40 + blades * 20
    alb[..., 1] = 120 + n * 50 + blades * 30
    alb[..., 2] = 48 + n * 20
    save_set('grass', alb, blades * 0.6 + n * 0.4, np.zeros((S, S)) + 0.9, None, 2.0)
grass()

def wood():
    alb = np.zeros((S, S, 3)); hgt = np.zeros((S, S)); rgh = np.zeros((S, S)) + 0.7
    plank = 64
    n = fbm(S, S, 4, 4)
    for i in range(S // plank):
        shade = 0.85 + rng.random() * 0.3
        y0 = i * plank
        grain = np.sin(np.linspace(0, 40, S)[None, :] + n[y0:y0 + plank] * 12) * 0.5 + 0.5
        alb[y0:y0 + plank] = np.stack([150 * shade + grain * 20, 104 * shade + grain * 12, 66 * shade + grain * 8], axis=-1)
        hgt[y0:y0 + plank] = 0.6 + grain * 0.05
        alb[y0 + plank - 3:y0 + plank] *= 0.45; hgt[y0 + plank - 3:y0 + plank] = 0.2
    save_set('wood_planks', alb, hgt, rgh, None, 3.0)
wood()

def marble():
    n = fbm(S, S, 6, 3)
    veins = np.abs(np.sin((np.mgrid[0:S, 0:S][1] / S * 6 + n * 5) * math.pi))
    v = (veins < 0.05).astype(float) * 0.5 + (veins < 0.12) * 0.2
    alb = np.zeros((S, S, 3)) + np.array([238, 235, 229]) - v[..., None] * np.array([70, 70, 64])
    yy, xx = np.mgrid[0:S, 0:S]
    g = ((xx % 256) < 2) | ((yy % 256) < 2)
    alb[g] = [180, 176, 170]
    hgt = 0.6 - g * 0.3
    save_set('marble', alb, hgt, np.zeros((S, S)) + 0.12 + v * 0.2, None, 2.0)
marble()

def carpet():
    n = fbm(S, S, 5, 40)
    fib = rng.random((S, S))
    alb = np.zeros((S, S, 3)) + np.array([92, 32, 46]) * (0.85 + n[..., None] * 0.2 + fib[..., None] * 0.12)
    save_set('carpet', alb, fib * 0.6 + n * 0.3, np.zeros((S, S)) + 0.98, None, 1.5)
carpet()

def plaster(name, base, amt=0.05, rough=0.85):
    n = fbm(S, S, 6, 12)
    alb = tint_noise(S, S, base, amt, 10)
    save_set(name, alb, n * 0.3 + rng.random((S, S)) * 0.05, np.zeros((S, S)) + rough, None, 2.0)
plaster('plaster', (246, 244, 240))
plaster('concrete', (176, 176, 172), 0.12, 0.92)

def metal():
    n = fbm(S, S, 4, 64)
    brushed = blur_wrap(rng.random((S, S)), 0)
    brushed = np.mean([np.roll(brushed, k, axis=1) for k in range(12)], axis=0)
    alb = np.zeros((S, S, 3)) + 150 + (brushed[..., None] - 0.5) * 40 + (n[..., None] - 0.5) * 20
    save_set('metal_brushed', alb, brushed * 0.2, np.zeros((S, S)) + 0.35, np.zeros((S, S)) + 0.95, 1.0)
metal()

# awning stripes, crosswalk, water normal
aw = np.zeros((256, 256, 3))
for i in range(8):
    aw[:, i * 32:(i + 1) * 32] = 255 if i % 2 == 0 else 214
save_rgb(aw, 'awning_albedo')

zb = Image.new('RGBA', (512, 128), (0, 0, 0, 0))
d = ImageDraw.Draw(zb)
for i in range(8):
    d.rectangle([i * 64 + 8, 0, i * 64 + 44, 127], fill=(238, 238, 236, 235))
zb.save(f'{TEX}/crosswalk_albedo.png', optimize=True)

W2 = 512
wh = np.zeros((W2, W2))
for k in range(1, 9):
    for _ in range(3):
        ax, ay = rng.normal(), rng.normal()
        ph = rng.random() * 6.28
        yy, xx = np.mgrid[0:W2, 0:W2] / W2
        wh += np.sin((xx * round(ax * k) + yy * round(ay * k)) * 2 * math.pi + ph) / k
wh = (wh - wh.min()) / np.ptp(wh)
normal_from_height(wh, 6.0).save(f'{TEX}/water_normal.png', optimize=True)

# ---------------- sign & billboard atlases ----------------
def font(size):
    for f in ['/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf']:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()

SIGNS = ['PALM CAFE', 'LAUNDROMAT', 'PIZZA', 'DELI', 'GYM', 'TACOS', 'NAILS', 'DINER', 'LIQUOR', 'BARBER', 'PHARMACY', 'BOOKS',
         'SURF SHOP', 'ARCADE', 'BAKERY', 'SUSHI', 'TATTOO', 'CELL FIX', 'BODEGA', 'HOTEL', 'MOTEL', 'BAR', 'SHOES', 'FLOWERS',
         'VINYL', 'THRIFT', 'BURGERS', 'DONUTS', 'JUICE', 'CUBAN CAFE', 'CHECKS CASHED', 'DENTIST']
BG = ['#e2434b', '#2c8f6e', '#2e6fd1', '#f2a531', '#8b4bd1', '#1d9fb5', '#e85d9a', '#22262c', '#c0392b', '#16a085']
at = Image.new('RGB', (1024, 512), (0, 0, 0))
d = ImageDraw.Draw(at)
f = font(36)
for i, s in enumerate(SIGNS):
    cx, cy = (i % 4) * 256, (i // 4) * 64
    d.rectangle([cx + 2, cy + 2, cx + 253, cy + 61], fill=BG[i % len(BG)])
    d.rectangle([cx + 8, cy + 8, cx + 247, cy + 55], outline=(255, 255, 255), width=3)
    tw = d.textlength(s, font=f)
    ff = f if tw < 226 else font(int(36 * 226 / tw))
    d.text((cx + 128, cy + 33), s, fill='white', font=ff, anchor='mm')
at.save(f'{TEX}/signs_atlas.png', optimize=True)

ADS = [('LEONIDA LOTTERY', 'Play today. Win tomorrow.', (255, 79, 163)), ('SUNSET 98.1 FM', 'Hits all day on the coast', (255, 179, 71)),
       ('GATOR BAIL BONDS', '24/7  -  we answer', (44, 143, 110)), ('PALM AIR', 'Fly the coast for less', (29, 159, 181))]
ad = Image.new('RGB', (1024, 512))
d = ImageDraw.Draw(ad)
for i, (t1, t2, c) in enumerate(ADS):
    cx, cy = (i % 2) * 512, (i // 2) * 256
    for y in range(256):
        k = y / 255
        d.line([(cx, cy + y), (cx + 511, cy + y)], fill=tuple(int(c[j] * (1 - k * 0.6) + 26 * k) for j in range(3)))
    d.ellipse([cx + 330, cy - 50, cx + 560, cy + 180], fill=tuple(min(255, v + 30) for v in c))
    d.text((cx + 28, cy + 110), t1, fill='white', font=font(58), anchor='lm')
    d.text((cx + 30, cy + 175), t2, fill=(255, 255, 255), font=font(28), anchor='lm')
    d.rectangle([cx + 3, cy + 3, cx + 508, cy + 252], outline=(17, 17, 17), width=8)
ad.save(f'{TEX}/ads_atlas.png', optimize=True)

# ---------------- audio ----------------
SR = 22050
def write(name, sig, sr=SR):
    sig = np.clip(sig, -1, 1)
    with wave.open(f'{AUD}/{name}.wav', 'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes((sig * 32000).astype('<i2').tobytes())
def t(d): return np.arange(int(SR * d)) / SR
def env(n, a=0.002, decay=0.1):
    x = np.arange(n) / SR
    return np.minimum(1, x / a) * np.exp(-x / decay)
def lowpass(x, k):
    out = np.copy(x)
    for i in range(1, len(x)): out[i] = out[i - 1] + k * (x[i] - out[i - 1])
    return out
def noise(d): return rng.uniform(-1, 1, int(SR * d))

n = noise(0.5); write('shot', lowpass(n, 0.35) * env(len(n), 0.001, 0.07) * 1.6 + np.sin(2 * np.pi * 70 * t(0.5)) * env(len(n), 0.001, 0.08))
n = noise(0.2); write('shot_suppressed', (n - lowpass(n, 0.3)) * env(len(n), 0.001, 0.03) * 0.9)
n = noise(0.4); write('npc_shot', lowpass(n, 0.3) * env(len(n), 0.001, 0.06) * 1.2)
n = noise(0.6); g = (n - lowpass(n, 0.6)) * env(len(n), 0.001, 0.12)
for k in range(12):
    s = int(rng.random() * len(n) * 0.6); g[s:s + 400] += np.sin(2 * np.pi * rng.uniform(2500, 5000) * t(400 / SR)) * 0.3 * np.exp(-t(400 / SR) * 30)
write('glass', g)
tt = t(0.22); write('cash', np.sign(np.sin(2 * np.pi * np.where(tt < 0.08, 880, 1320) * tt)) * 0.25 * np.exp(-tt * 9))
n = noise(1.6); write('boom', lowpass(n, 0.05) * env(len(n), 0.002, 0.45) * 3 + np.sin(2 * np.pi * 45 * t(1.6)) * env(len(n), 0.002, 0.3))
n = noise(0.25); write('kick', lowpass(n, 0.1) * env(len(n), 0.001, 0.05) * 2)
n = noise(0.6); write('crash', lowpass(n, 0.2) * env(len(n), 0.001, 0.15) * 1.8)
tt = t(0.04); write('click', np.sign(np.sin(2 * np.pi * 1800 * tt)) * 0.2 * np.exp(-tt * 80))
tt = t(0.08); write('beep', np.sign(np.sin(2 * np.pi * 1200 * tt)) * 0.25)
tt = t(0.6); write('bad', np.sign(np.sin(2 * np.pi * np.where(tt < 0.25, 220, 160) * tt)) * 0.2 * np.exp(-tt * 3))
tt = t(0.35); write('good', np.sin(2 * np.pi * np.where(tt < 0.12, 660, 990) * tt) * 0.35 * np.exp(-tt * 5))
n = noise(0.12); write('hit', (n - lowpass(n, 0.4)) * env(len(n), 0.001, 0.03) * 1.5)
tt = t(0.5); write('drill', (np.sign(np.sin(2 * np.pi * 180 * tt)) * 0.3 + noise(0.5) * 0.2) * (0.7 + 0.3 * np.sin(2 * np.pi * 9 * tt)))
# loops (seamless lengths)
tt = t(1.0); f = np.where((tt * 2.0) % 1 < 0.5, 950, 760); ph = np.cumsum(2 * np.pi * f / SR)
write('alarm_loop', np.sign(np.sin(ph)) * 0.25)
tt = t(2.0); f = 720 + 320 * np.sin(2 * np.pi * 0.5 * tt); ph = np.cumsum(2 * np.pi * f / SR)
write('siren_loop', lowpass(2 * ((ph / (2 * np.pi)) % 1) - 1, 0.5) * 0.45)
# engine loop: 1 s, harmonic-rich around 55 Hz (pitch-shifted in game)
tt = t(1.0); base = 55.0
eng = sum(np.sin(2 * np.pi * base * k * tt + rng.random() * 6) / k ** 0.9 for k in range(1, 14))
eng += 0.35 * np.sin(2 * np.pi * base * 0.5 * tt)
eng = lowpass(eng, 0.25) * 0.28 * (1 + 0.15 * np.sin(2 * np.pi * base * 0.5 * tt))
write('engine_loop', eng)
n = noise(1.0); s = n - lowpass(n, 0.55); s = lowpass(s, 0.6) * (0.8 + 0.2 * np.sin(2 * np.pi * 13 * t(1.0)))
write('screech_loop', s * 0.6)
n = noise(1.0); write('wind_loop', lowpass(n, 0.02) * 1.6)
print('assets generated')

# police door decal
pd = Image.new('RGB', (256, 64), (245, 245, 245))
d = ImageDraw.Draw(pd)
d.text((128, 33), 'POLICE', fill=(18, 48, 107), font=font(44), anchor='mm')
pd.save(f'{TEX}/police_decal.png')
print('decal ok')
