"""Realistic characters from CC0 MakeHuman assets.

    bash tools/blender/fetch_makehuman.sh          # once: CC0 asset data -> ~/mh/core/data
    python tools/blender/make_mh_humans.py [--preview]

Writes
    assets/models/human_m.glb, human_f.glb    rig + every part mesh + all animation clips
    assets/characters/atlas_albedo.webp       skins, clothes, shoes, eyes, gear (4096^2)
    assets/characters/atlas_normal.webp       matching normal maps (2048^2)
    assets/characters/atlas_hair.webp         hair cards, eyebrows, eyelashes (RGBA)
    assets/characters/humans.json             part catalogue for the game (slots, masks...)

How it works (see the reference sheets in the commit that introduced this):
  * MakeHuman base mesh + macro targets shaped toward the reference sheets (lean athletic
    male ~1.81 m, athletic female ~1.70 m), then the game-resolution proxy bodies
    (male1591 / female1605, ~3k triangles) and CC0 clothes, shoes, hair cards, brows,
    lashes and eyes are fitted exactly as MakeHuman fits them.
  * The skeleton is our game rig (same bone names/axes as before, plus finger joints)
    placed on MakeHuman's joint centroids; weights are MakeHuman's painted default-rig
    weights mapped onto our bones. The rest pose is then normalised (straight legs,
    our A-pose arm angle) and scaled so the hips sit at 0.96 m, so every hand-keyed /
    IK animation from human_library.py plays on the new bodies unchanged.
  * Suits are split into tops and bottoms (mesh islands) so they mix and match; each part
    has a bit in a 32-bit mask stored in the body's vertex colours, marking the skin it
    covers. The game removes covered body triangles when it assembles an outfit.
  * All textures are packed into shared atlases; garments are tinted per character in
    the shader (luminance x colour), so a handful of textures give endless variety.
"""
import os
import sys
import json
import math
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix
from mathutils.kdtree import KDTree
from PIL import Image, ImageFilter
import bl_util as U
import mh
import mh_bl
import humans as H
import human_anims as HA
import human_library as HL
import make_humans as MHU

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(ROOT, "assets", "models")
CHARS = os.path.join(ROOT, "assets", "characters")
HIP_Z = 0.96

# ------------------------------------------------------------------ catalogue
SLOT = {"skin": 0, "top": 1, "bottom": 2, "shoes": 3, "hat": 4, "gear": 5, "fixed": 6, "hair": 7}

GENDERS = {
    "m": {
        # lean, athletic (reference: male sheet)
        "params": dict(gender=1.0, age=0.5, muscle=0.66, weight=0.44, height=0.5, proportions=0.85, race={"caucasian": 1.0},
                       extra={"measure/measure-waist-circ-decr.target": 0.35, "measure/measure-shoulder-dist-incr.target": 0.25,
                              "measure/measure-upperarm-circ-incr.target": 0.2, "torso/torso-vshape-incr.target": 0.3}),
        "height": 1.81,
        "proxy": "male1591",
        "skins": ["young_caucasian_male", "young_african_male", "young_asian_male"],
        "suits": {   # garment -> {island class: part name}
            "male_casualsuit04": {"top": "tee", "bottom": "jeans"},
            "male_casualsuit02": {"top": "longsleeve"},
            "male_casualsuit03": {"top": "shirt"},
            "male_casualsuit05": {"top": "jacket"},
            "male_elegantsuit01": {"top": "suit_jacket", "bottom": "suit_pants"},
        },
        "shoes": {"shoes06": "sneakers", "shoes05": "sneakers_white", "shoes01": "boots", "shoes04": "shoes_black"},
        "hairs": {"short02": "messy", "short01": "side_part", "short04": "buzz", "afro01": "afro"},
        "decimate": {"male_elegantsuit01": 0.3, "male_casualsuit05": 0.6, "male_casualsuit03": 0.75},
    },
    "f": {
        # athletic, slim waist (reference: female sheet)
        "params": dict(gender=0.0, age=0.5, muscle=0.62, weight=0.42, height=0.5, proportions=0.85, race={"caucasian": 1.0},
                       extra={"measure/measure-waist-circ-decr.target": 0.4, "measure/measure-upperarm-circ-incr.target": 0.1}),
        "height": 1.70,
        "proxy": "female1605",
        "skins": ["young_caucasian_female", "young_african_female", "young_asian_female"],
        "suits": {
            "female_casualsuit01": {"top": "tee", "bottom": "jeans"},
            "female_casualsuit02": {"top": "tee_b", "bottom": "shorts"},
            "female_sportsuit01": {"top": "crop", "bottom": "leggings"},
            "female_elegantsuit01": {"top": "blouse", "bottom": "skirt"},
        },
        "tank_from": "crop",      # sleeveless cropped tank (partner reference) cut from the crop tee
        "shoes": {"shoes06": "sneakers", "shoes05": "sneakers_white", "shoes03": "flats", "shoes04": "shoes_black"},
        "hairs": {"ponytail01": "ponytail", "bob02": "bob", "long01": "long"},
        "decimate": {},
    },
}
SHOE_DECIMATE = 0.22

# albedo atlas: 4x4 tiles of 1024; the last tile is 4x4 small tiles of 256
TILES = {
    "young_caucasian_male": (0, 0), "young_african_male": (1, 0), "young_asian_male": (2, 0),
    "young_caucasian_female": (3, 0), "young_african_female": (0, 1), "young_asian_female": (1, 1),
    "male_casualsuit04": (2, 1), "male_casualsuit02": (3, 1), "male_casualsuit03": (0, 2), "male_casualsuit05": (1, 2),
    "male_elegantsuit01": (2, 2), "female_casualsuit01": (3, 2), "female_casualsuit02": (0, 3), "female_sportsuit01": (1, 3),
    "female_elegantsuit01": (2, 3),
    "hero_m": (0, 4), "hero_f": (1, 4),     # player / partner: faces projected from the reference sheets
}
SMALL = {"shoes01": (0, 0), "shoes03": (1, 0), "shoes04": (2, 0), "shoes05": (3, 0), "shoes06": (0, 1), "eyes": (1, 1), "gear": (2, 1), "eyes_f": (3, 1)}
SMALL_TILE = (3, 3)
# hair atlas 4096 x 2048: 4x2 tiles of 1024
HAIR_TILES = {"short02": (0, 0), "short01": (1, 0), "short04": (2, 0), "afro01": (3, 0), "ponytail01": (0, 1), "bob02": (1, 1), "long01": (2, 1)}
BROW_TILE = (3, 1)   # brows top half, lashes bottom half
AW, AH, NW, NH = 4096, 5120, 2048, 2560
REFS = os.environ.get("REF_DIR", os.path.join(ROOT, "tools", "reference"))
# reference sheets (front close-ups): eye centres (character right, left) and mouth centre, px
HEROES = {
    "m": {"tile": "hero_m", "image": "male_ref.png", "eyes": ((1216, 181), (1281, 181)), "mouth": (1249, 250), "panel": (1148, 48, 1346, 357)},
    "f": {"tile": "hero_f", "image": "female_ref.png", "eyes": ((1318, 192.5), (1402, 192.5)), "mouth": (1360.5, 280), "panel": (1201, 14, 1533, 401)},
}
GEAR_PATCHES = {"fabric": (0.25, 0.25), "black": (0.75, 0.25), "metal": (0.25, 0.75), "glass": (0.75, 0.75)}


def tile_rect(name):
    """(x0, y0, w, h) in albedo-atlas pixels (top-left origin)."""
    if name in TILES:
        c, r = TILES[name]
        return (c * 1024, r * 1024, 1024, 1024)
    c, r = SMALL[name]
    return (SMALL_TILE[0] * 1024 + c * 256, SMALL_TILE[1] * 1024 + r * 256, 256, 256)


def hair_rect(name):
    if name == "brows":
        return (BROW_TILE[0] * 1024, BROW_TILE[1] * 1024, 1024, 512)
    if name == "lashes":
        return (BROW_TILE[0] * 1024, BROW_TILE[1] * 1024 + 512, 1024, 512)
    c, r = HAIR_TILES[name]
    return (c * 1024, r * 1024, 1024, 1024)


def remap_uv(obj_uv, rect, aw, ah):
    """Asset UVs (0..1, Blender bottom-left) -> atlas UVs for a tile rect (top-left px)."""
    x0, y0, w, h = rect
    u = (x0 + obj_uv[:, 0] * w) / aw
    v = 1.0 - (y0 + (1.0 - obj_uv[:, 1]) * h) / ah
    return np.stack([u, v], axis=1)


# ------------------------------------------------------------------ textures
def _load(fn, size, mode="RGB"):
    im = Image.open(fn)
    if mode == "RGB" and im.mode == "RGBA":
        bg = Image.new("RGB", im.size, (128, 128, 128))
        bg.paste(im, mask=im.split()[3])
        im = bg
    return im.convert(mode).resize(size, Image.LANCZOS)


# shirt regions (fractions of the texture) and the horizontal offset from the logo'd front
# panel to the plain back panel, per garment texture
CLEAN = {   # shirt region, logo box (x0, y0, x1, y1 fractions) or None
    "male_casualsuit04": (lambda y, x: y < 0.42, (0.49, 0.08, 0.67, 0.27)),
    "male_casualsuit02": (lambda y, x: (y < 0.42) | (x > 0.76), (0.45, 0.09, 0.66, 0.30), -0.40),
    "female_casualsuit01": (lambda y, x: (y < 0.47) | (x > 0.74), (0.66, 0.15, 0.92, 0.38)),
    "female_casualsuit02": (lambda y, x: (y < 0.37) | ((x > 0.70) & (y > 0.55)), (0.64, 0.12, 0.92, 0.36)),
    "female_sportsuit01": (lambda y, x: (y < 0.47) | ((x > 0.66) & (y > 0.5)), None),
}


def _blur(a, r):
    return np.stack([np.asarray(Image.fromarray(np.clip(a[..., k], 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))).astype(np.float32)
                     for k in range(a.shape[-1])], -1)


def logo_mask(im, region):
    """Orange piping / logo strokes inside the shirt region of a garment texture."""
    a = np.asarray(im).astype(np.float32) / 255.0
    h, w = a.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    reg = region(yy / h, xx / w)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1e-4)
    orange = (r > g) & (g > b) & (sat > 0.4) & (r > 0.4)
    lum = a @ np.array([0.3, 0.59, 0.11])
    bl = np.asarray(Image.fromarray((lum * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(9))).astype(np.float32) / 255.0
    strokes = (np.abs(lum - bl) > 0.13) & (sat < 0.4)
    m = (orange | strokes) & reg
    return np.asarray(Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9))) > 0


def panel_offset(img, box):
    """Horizontal offset from the logo panel to the other big cloth panel (same rows)."""
    a = np.asarray(img).astype(np.float32)
    h, w = a.shape[:2]
    bgc = a[2, 2]
    rows = a[int(box[1] * h):int(box[3] * h)]
    cloth = (np.abs(rows - bgc).sum(-1) > 40).mean(0) > 0.6
    runs, x = [], 0
    while x < w:
        if cloth[x]:
            x0 = x
            while x < w and cloth[x]:
                x += 1
            runs.append((x0, x))
        x += 1
    runs = [r for r in runs if r[1] - r[0] > 0.12 * w]
    cx = (box[0] + box[2]) / 2 * w
    front = min(runs, key=lambda r: abs((r[0] + r[1]) / 2 - cx))
    others = [r for r in runs if r != front]
    back = max(others, key=lambda r: r[1] - r[0])
    return ((back[0] + back[1]) / 2 - (front[0] + front[1]) / 2) / w


def clean_logos(img, m, box, dx=None):
    """Logo box: transplant fabric from the plain back panel (feathered); thin piping:
    refill from a normalised blur of the surrounding cloth. For albedo and normal maps."""
    a = np.asarray(img).astype(np.float32)
    h, w = a.shape[:2]
    if m.shape != (h, w):
        m = np.asarray(Image.fromarray((m * 255).astype(np.uint8)).resize((w, h), Image.NEAREST)) > 0
    out = a.copy()
    if box is not None:
        x0, y0, x1, y1 = int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)
        sx = int(round(dx * w))
        bx = np.zeros((h, w), np.float32)
        bx[y0:y1, x0:x1] = 255
        feather = np.asarray(Image.fromarray(bx.astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.01 * w))).astype(np.float32)[..., None] / 255.0
        src = np.roll(a, -sx, axis=1)
        out = out * (1 - feather) + src * feather
        m = m & (feather[..., 0] < 0.5)
    keep = (~m).astype(np.float32)[..., None]
    for rad in (4, 10, 24):
        num = _blur(out * keep, rad)
        den = _blur(keep * 255.0, rad)[..., :1] / 255.0
        fill = num / np.maximum(den, 1e-3)
        sel = m & (den[..., 0] > 0.25)
        out[sel] = fill[sel]
        keep[sel] = 1.0
        m = m & ~sel
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def build_atlases():
    t0 = time.time()
    alb = Image.new("RGB", (AW, AH), (90, 90, 90))
    nrm = Image.new("RGB", (NW, NH), (128, 128, 255))
    hair = Image.new("RGBA", (4096, 2048), (60, 45, 35, 0))
    k = NW / AW     # same layout, half resolution
    for g in GENDERS.values():
        for s in g["skins"]:
            m = mh.read_mhmat(mh.path("skins", s, s + ".mhmat"))
            x, y, w, h = tile_rect(s)
            alb.paste(_load(m["diffuseTexture"], (w, h)), (x, y))
        for gname in list(g["suits"].keys()) + list(g["shoes"].keys()):
            px, ob, mat = mh_bl.asset("clothes", gname)
            x, y, w, h = tile_rect(gname)
            d = _load(mat["diffuseTexture"], (w, h))
            lm = None
            if gname in CLEAN:
                lm = logo_mask(d, CLEAN[gname][0])
                box = CLEAN[gname][1]
                pdx = (CLEAN[gname][2] if len(CLEAN[gname]) > 2 else panel_offset(d, box)) if box else None
                d = clean_logos(d, lm, box, pdx)
            if mat.get("aomapTexture") and os.path.exists(mat["aomapTexture"]):
                ao = np.asarray(_load(mat["aomapTexture"], (w, h), "L")).astype(np.float32) / 255.0
                d = Image.fromarray((np.asarray(d).astype(np.float32) * (0.35 + 0.65 * ao[..., None])).clip(0, 255).astype(np.uint8))
            alb.paste(d, (x, y))
            if mat.get("normalmapTexture") and os.path.exists(mat["normalmapTexture"]):
                nm_ = _load(mat["normalmapTexture"], (int(w * k), int(h * k)))
                if lm is not None:
                    nm_ = clean_logos(nm_, lm, box, pdx)
                nrm.paste(nm_, (int(x * k), int(y * k)))
        for hname in g["hairs"]:
            hpx, hob, hmat = mh_bl.asset("hair", hname)
            x, y, w, h = hair_rect(hname)
            hair.paste(_load(hmat["diffuseTexture"], (w, h), "RGBA"), (x, y))
    # eyes
    for tile, mat_name in (("eyes", "brown"), ("eyes_f", "brownlight")):
        em = mh.read_mhmat(mh.path("eyes", "materials", mat_name + ".mhmat"))
        x, y, w, h = tile_rect(tile)
        e = np.asarray(_load(em["diffuseTexture"], (w, h))).astype(np.float32)
        grey = e.mean(-1, keepdims=True)
        e = (grey + (e - grey) * 0.7) * 0.88         # calmer irises under game lighting
        alb.paste(Image.fromarray(np.clip(e, 0, 255).astype(np.uint8)), (x, y))
    # gear patches: woven fabric (tinted in game), black nylon, metal, dark glass
    x, y, w, h = tile_rect("gear")
    rng = np.random.default_rng(3)
    yy, xx = np.mgrid[0:128, 0:128]
    weave = 0.9 + 0.06 * np.sign(np.sin(xx * 1.6)) * np.sign(np.sin(yy * 1.6)) + rng.normal(0, 0.02, (128, 128))
    for nm, base in (("fabric", 0.8), ("black", 0.07), ("metal", 0.6), ("glass", 0.03)):
        cx, cy = GEAR_PATCHES[nm]
        patch = np.clip(weave * base, 0, 1)
        img = Image.fromarray((np.stack([patch] * 3, -1) * 255).astype(np.uint8))
        alb.paste(img, (int(x + cx * w - 64), int(y + cy * h - 64)))
    # brows / lashes
    for nm, asset, rect in (("brows", ("eyebrows", "eyebrow001"), hair_rect("brows")), ("lashes", ("eyelashes", "eyelashes01"), hair_rect("lashes"))):
        px, ob, mat = mh_bl.asset(*asset)
        x, y, w, h = rect
        hair.paste(_load(mat["diffuseTexture"], (w, h), "RGBA"), (x, y))
    # bleed hair colour into transparent texels so mip-mapped edges don't go dark
    ha = np.asarray(hair).astype(np.float32)
    a = ha[..., 3:4] / 255.0
    num = np.stack([np.asarray(Image.fromarray((ha[..., c] * a[..., 0]).astype(np.uint8)).filter(ImageFilter.GaussianBlur(12))).astype(np.float32) for c in range(3)], -1)
    den = np.asarray(Image.fromarray((a[..., 0] * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(12))).astype(np.float32)[..., None] / 255.0
    fill = num / np.maximum(den, 1e-3)
    ha[..., :3] = np.where(a > 0.02, ha[..., :3], np.clip(fill, 0, 255))
    hair = Image.fromarray(ha.astype(np.uint8), "RGBA")
    print("atlases", round(time.time() - t0, 1), "s")
    return alb, nrm, hair


def save_atlases(alb, nrm, hair):
    os.makedirs(CHARS, exist_ok=True)
    alb.save(os.path.join(CHARS, "atlas_albedo.webp"), quality=90, method=6)
    nrm.save(os.path.join(CHARS, "atlas_normal.webp"), quality=92, method=6)
    hair.save(os.path.join(CHARS, "atlas_hair.webp"), quality=92, method=6)


def _smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def _bilinear(img, u, v):
    h, w = img.shape[:2]
    u = np.clip(u, 0, w - 1.001)
    v = np.clip(v, 0, h - 1.001)
    x0 = u.astype(int)
    y0 = v.astype(int)
    fx = (u - x0)[:, None]
    fy = (v - y0)[:, None]
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy) + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)


def project_face(gk, skin_name, P, pob, eyes_pts, mouth, T=1024):
    """Skin tile for the player / partner: MakeHuman's photo skin, colour-matched to the
    reference sheet, with the sheet's face projected onto the head (front orthographic;
    affine fitted to both eye centres + the mouth). Fades out toward the hairline, jaw,
    neck and the sides of the head, where the MakeHuman skin takes over."""
    H = HEROES[gk]
    m = mh.read_mhmat(mh.path("skins", skin_name, skin_name + ".mhmat"))
    base = np.asarray(_load(m["diffuseTexture"], (T, T))).astype(np.float32)
    ref = np.asarray(Image.open(os.path.join(REFS, H["image"])).convert("RGB")).astype(np.float32)
    eR = eyes_pts[eyes_pts[:, 0] < 0].mean(0)
    eL = eyes_pts[eyes_pts[:, 0] > 0].mean(0)
    S = np.array([[eR[0], eR[2], 1.0], [eL[0], eL[2], 1.0], [mouth[0], mouth[2], 1.0]])
    D = np.array([H["eyes"][0], H["eyes"][1], H["mouth"]], dtype=np.float64)
    M = np.linalg.solve(S, D)               # (x, z, 1) -> (u, v) image px
    # vertex normals of the proxy body
    N = np.zeros_like(P)
    tris = []
    for f in pob["faces"]:
        vi = [a for a, _ in f]
        ti = [b for _, b in f]
        for k in range(1, len(vi) - 1):
            a, b, c = vi[0], vi[k], vi[k + 1]
            n = np.cross(P[b] - P[a], P[c] - P[a])
            N[[a, b, c]] += n
            tris.append(((a, b, c), (ti[0], ti[k], ti[k + 1])))
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    nose = np.argmin(P[:, 1] + np.abs(P[:, 0]) * 3 + np.abs(P[:, 2] - (eR[2] - 0.035)) * 3)
    if N[nose, 1] > 0:
        N = -N
    uvs = pob["uv"]
    pos = np.zeros((T, T, 3), np.float32)
    nrm = np.zeros((T, T, 3), np.float32)
    hit = np.zeros((T, T), bool)
    zmin = mouth[2] - 0.2
    for (a, b, c), (ta, tb, tc) in tris:
        if max(P[a][2], P[b][2], P[c][2]) < zmin:
            continue
        uv = np.array([uvs[ta], uvs[tb], uvs[tc]])
        px = uv[:, 0] * T
        py = (1.0 - uv[:, 1]) * T
        x0, x1 = int(max(0, px.min() - 1)), int(min(T - 1, px.max() + 1))
        y0, y1 = int(max(0, py.min() - 1)), int(min(T - 1, py.max() + 1))
        if x1 < x0 or y1 < y0:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        den = (py[1] - py[2]) * (px[0] - px[2]) + (px[2] - px[1]) * (py[0] - py[2])
        if abs(den) < 1e-9:
            continue
        l0 = ((py[1] - py[2]) * (gx - px[2]) + (px[2] - px[1]) * (gy - py[2])) / den
        l1 = ((py[2] - py[0]) * (gx - px[2]) + (px[0] - px[2]) * (gy - py[2])) / den
        l2 = 1 - l0 - l1
        ins = (l0 >= -0.02) & (l1 >= -0.02) & (l2 >= -0.02)
        if not ins.any():
            continue
        L = np.stack([l0, l1, l2], -1)[ins]
        yy, xx = gy[ins].astype(int), gx[ins].astype(int)
        pos[yy, xx] = L @ np.array([P[a], P[b], P[c]])
        nrm[yy, xx] = L @ np.array([N[a], N[b], N[c]])
        hit[yy, xx] = True
    sel = hit
    p3 = pos[sel]
    n3 = nrm[sel] / np.maximum(np.linalg.norm(nrm[sel], axis=1, keepdims=True), 1e-6)
    half_ipd = abs(eL[0] - eR[0]) / 2
    ez = (eR[2] + eL[2]) / 2
    w = _smooth(0.18, 0.62, -n3[:, 1])
    w *= _smooth(ez + 0.105, ez + 0.07, p3[:, 2])            # hairline
    w *= _smooth(mouth[2] - 0.15, mouth[2] - 0.095, p3[:, 2])  # down the neck to the collar
    w *= _smooth(half_ipd * 2.6, half_ipd * 2.05, np.abs(p3[:, 0]))
    uvimg = np.c_[p3[:, 0], p3[:, 2], np.ones(len(p3))] @ M
    # only sample inside the close-up panel (fade 12 px from its frame)
    x0, y0, x1, y1 = H["panel"]
    w *= _smooth(x0, x0 + 12, uvimg[:, 0]) * _smooth(x1, x1 - 12, uvimg[:, 0]) * _smooth(y0, y0 + 12, uvimg[:, 1]) * _smooth(y1, y1 - 12, uvimg[:, 1])
    samp = _bilinear(ref, uvimg[:, 0], uvimg[:, 1])
    out = base.copy()
    strong = w > 0.6
    ratio = samp[strong].mean(0) / np.maximum(base[sel][strong].mean(0), 1.0)
    out *= ratio                                             # whole-body skin matches the face
    o = out[sel]
    out[sel] = o * (1 - w[:, None]) + samp * w[:, None]
    print(gk, "face projected:", int(strong.sum()), "texels, skin ratio", np.round(ratio, 3))
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def mean_lum(img, uv, alpha=False):
    """Mean luminance of the texels under a part's UVs (atlas UVs, Blender convention)."""
    hgt, wid = img.shape[:2]
    xs = np.clip((uv[:, 0] * wid).astype(int), 0, wid - 1)
    ys = np.clip(((1.0 - uv[:, 1]) * hgt).astype(int), 0, hgt - 1)
    px = img[ys, xs].astype(np.float32) / 255.0
    lum = px[:, :3] @ np.array([0.3, 0.59, 0.11])
    if alpha:
        sel = px[:, 3] > 0.5
        lum = lum[sel] if sel.any() else lum
    return float(max(0.05, lum.mean()))


# ------------------------------------------------------------------ rig
def map_bone(b):
    side = b[-2:] if b.endswith((".L", ".R")) else ""
    n = b[:-2] if side else b
    if n in ("root", "spine05", "pelvis"):
        return "hips"
    if n in ("spine04", "spine03"):
        return "spine"
    if n in ("spine02", "spine01", "breast"):
        return "chest"
    if n.startswith("neck"):
        return "neck"
    if n in ("clavicle", "shoulder01"):
        return "shoulder" + side
    if n.startswith("upperarm"):
        return "upper_arm" + side
    if n.startswith("lowerarm"):
        return "forearm" + side
    if n == "wrist" or n.startswith("metacarpal") or n == "finger1-1":
        return "hand" + side
    if n == "finger1-2":
        return "thumb" + side
    if n == "finger1-3":
        return "thumb_tip" + side
    if n.startswith("finger"):
        k = n.split("-")[1]
        return {"1": "fingers", "2": "fingers_mid", "3": "fingers_tip"}[k] + side
    if n.startswith("upperleg"):
        return "thigh" + side
    if n.startswith("lowerleg"):
        return "shin" + side
    if n == "foot":
        return "foot" + side
    if n.startswith("toe"):
        return "toe" + side
    return "head"


EXTRA_BONES = ["fingers_mid", "fingers_tip", "thumb_tip"]
TOP_BONES = {"spine", "chest", "neck", "shoulder.L", "shoulder.R", "upper_arm.L", "upper_arm.R", "forearm.L", "forearm.R", "hand.L", "hand.R"}
BOTTOM_BONES = {"hips", "thigh.L", "thigh.R", "shin.L", "shin.R"}


def rig_joints(bv):
    """Our bone (head, tail) positions in Blender coords from MakeHuman joints."""
    J = lambda b, end="head": mh.to_bl(mh.bone_head(bv, b) if end == "head" else mh.bone_tail(bv, b))
    out = {}
    hipL = J("upperleg01.L")
    hipR = J("upperleg01.R")
    hc = (hipL + hipR) / 2
    out["hips"] = ((0, hc[1], hc[2]), J("spine04"))
    out["spine"] = (J("spine04"), J("spine02"))
    out["chest"] = (J("spine02"), J("neck01"))
    out["neck"] = (J("neck01"), J("head"))
    out["head"] = (J("head"), J("head", "tail"))
    for s in ("L", "R"):
        out["shoulder." + s] = (J("clavicle." + s), J("upperarm01." + s))
        out["upper_arm." + s] = (J("upperarm01." + s), J("lowerarm01." + s))
        out["forearm." + s] = (J("lowerarm01." + s), J("wrist." + s))
        out["hand." + s] = (J("wrist." + s), J("finger3-1." + s))
        out["fingers." + s] = (J("finger3-1." + s), J("finger3-2." + s))
        out["fingers_mid." + s] = (J("finger3-2." + s), J("finger3-3." + s))
        out["fingers_tip." + s] = (J("finger3-3." + s), J("finger3-3." + s, "tail"))
        out["thumb." + s] = (J("finger1-2." + s), J("finger1-3." + s))
        out["thumb_tip." + s] = (J("finger1-3." + s), J("finger1-3." + s, "tail"))
        out["thigh." + s] = (J("upperleg01." + s), J("lowerleg01." + s))
        out["shin." + s] = (J("lowerleg01." + s), J("foot." + s))
        ball = np.mean([J("toe%d-1.%s" % (k, s)) for k in range(1, 6)], axis=0)
        out["foot." + s] = (J("foot." + s), ball)
        tip = ball + (ball - J("foot." + s)) * np.array([1, 1, 0]) / max(1e-4, np.linalg.norm((ball - J("foot." + s))[:2])) * 0.065
        out["toe." + s] = (ball, (tip[0], tip[1], ball[2] - 0.008))
    # symmetrise (MakeHuman is symmetric up to float noise)
    for n in list(out):
        if n.endswith(".L"):
            r = n[:-2] + ".R"
            hL, tL = np.array(out[n][0]), np.array(out[n][1])
            out[r] = (hL * [-1, 1, 1], tL * [-1, 1, 1])
    return out


ROLL = {"shin": "BACK", "foot": "UP", "toe": "UP"}
PARENT = {"hips": None, "spine": "hips", "chest": "spine", "neck": "chest", "head": "neck", "shoulder": "chest", "upper_arm": "shoulder",
          "forearm": "upper_arm", "hand": "forearm", "fingers": "hand", "fingers_mid": "fingers", "fingers_tip": "fingers_mid",
          "thumb": "hand", "thumb_tip": "thumb", "thigh": "hips", "shin": "thigh", "foot": "shin", "toe": "foot"}
ORDER = ["hips", "spine", "chest", "neck", "head", "shoulder", "upper_arm", "forearm", "hand", "fingers", "fingers_mid", "fingers_tip",
         "thumb", "thumb_tip", "thigh", "shin", "foot", "toe"]


def _axis(name):
    return {"FRONT": Vector((0, -1, 0)), "BACK": Vector((0, 1, 0)), "UP": Vector((0, 0, 1))}[name]


def build_rig(joints):
    arm = bpy.data.armatures.new("HumanRig")
    obj = bpy.data.objects.new("HumanRig", arm)
    U.link(obj)
    U.select_only(obj)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.edit_bones
    names = []
    for base in ORDER:
        for nm in ([base] if base in ("hips", "spine", "chest", "neck", "head") else [base + ".L", base + ".R"]):
            h, t = joints[nm]
            b = eb.new(nm)
            b.head = Vector(tuple(h))
            b.tail = Vector(tuple(t))
            b.align_roll(_axis(ROLL.get(base, "FRONT")))
            b.use_deform = True
            p = PARENT[base]
            if p:
                pn = p + nm[-2:] if (nm.endswith((".L", ".R")) and p not in ("hips", "spine", "chest", "neck", "head")) else p
                b.parent = eb[pn]
                b.use_connect = (eb[pn].tail - b.head).length < 1e-4
            names.append(nm)
    bpy.ops.object.mode_set(mode='OBJECT')
    return obj


def realign_rolls(rig):
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='EDIT')
    for b in rig.data.edit_bones:
        base = b.name[:-2] if b.name.endswith((".L", ".R")) else b.name
        if base in PARENT:
            b.align_roll(_axis(ROLL.get(base, "FRONT")))
    bpy.ops.object.mode_set(mode='OBJECT')


# target rest directions (armature space, .L side) = the old hand-built rig's A-pose,
# so the animation library's FK angles and IK targets stay valid
REST_DIRS = {
    "thigh": (0.0, 0.0, -1.0), "shin": (0.0, 0.054, -1.0),
    "upper_arm": (0.222, 0.012, -0.185), "forearm": (0.193, -0.032, -0.175), "hand": (0.053, -0.006, -0.05),
}


def normalise_pose(rig, meshes):
    """Pose MakeHuman's stance into our rest pose, bake it into the meshes, make it rest."""
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='POSE')
    for base in ("thigh", "shin", "upper_arm", "forearm", "hand", "foot"):
        for s, sx in (("L", 1), ("R", -1)):
            pb = rig.pose.bones[base + "." + s]
            bpy.context.view_layer.update()
            head = pb.head.copy()
            cur = (pb.tail - pb.head).normalized()
            if base == "foot":
                tgt = Vector((0.0, cur.y, cur.z)).normalized()   # point the feet straight ahead
            else:
                d = REST_DIRS[base]
                tgt = Vector((d[0] * sx, d[1], d[2])).normalized()
            q = cur.rotation_difference(tgt)
            M = Matrix.Translation(head) @ q.to_matrix().to_4x4() @ Matrix.Translation(-head)
            pb.matrix = M @ pb.matrix
            bpy.context.view_layer.update()
    bpy.ops.object.mode_set(mode='OBJECT')
    for m in meshes:
        U.select_only(m)
        for mod in list(m.modifiers):
            if mod.type == 'ARMATURE':
                bpy.ops.object.modifier_apply(modifier=mod.name)
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='POSE')
    bpy.ops.pose.armature_apply(selected=False)
    bpy.ops.object.mode_set(mode='OBJECT')
    realign_rolls(rig)


def add_weights(obj, wts):
    """wts: list of {bone: w} per vertex -> vertex groups (top 4, normalised)."""
    groups = {}
    for vi, d in enumerate(wts):
        items = sorted(d.items(), key=lambda kv: -kv[1])[:4]
        tot = sum(w for _, w in items)
        if tot <= 0:
            items, tot = [("hips", 1.0)], 1.0
        for b, w in items:
            if b not in groups:
                groups[b] = obj.vertex_groups.new(name=b)
            groups[b].add([vi], w / tot, 'REPLACE')


def arm_mod(obj, rig):
    md = obj.modifiers.new("Armature", 'ARMATURE')
    md.object = rig


def islands(obj):
    """Face index lists per connected mesh island."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    seen = set()
    out = []
    for f in bm.faces:
        if f.index in seen:
            continue
        stack = [f]
        isl = []
        seen.add(f.index)
        while stack:
            c = stack.pop()
            isl.append(c.index)
            for e in c.edges:
                for o in e.link_faces:
                    if o.index not in seen:
                        seen.add(o.index)
                        stack.append(o)
        out.append(isl)
    bm.free()
    return out


def keep_faces(obj, faces):
    """Delete all faces of obj not in `faces` (and loose verts)."""
    keep = set(faces)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    dead = [f for f in bm.faces if f.index not in keep]
    bmesh.ops.delete(bm, geom=dead, context='FACES')
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context='VERTS')
    bm.to_mesh(obj.data)
    bm.free()


def flare_hems(obj, top=0.24, low=0.10, amount=0.009):
    """Push trouser legs out a little toward the ankle so shoe collars stay inside."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.normal_update()
    for v in bm.verts:
        k = float(_smooth(top, low, np.array(v.co.z)))
        if k > 0:
            v.co += v.normal * amount * k
    bm.to_mesh(obj.data)
    bm.free()


def relax_boundary(obj, where, iters):
    """Smooth stair-stepped open edges (e.g. the tank top's cut armholes)."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    for _ in range(iters):
        new = {}
        for v in bm.verts:
            if not v.is_boundary or not where(v.co):
                continue
            nb = [e.other_vert(v) for e in v.link_edges if e.is_boundary]
            if len(nb) == 2:
                new[v] = v.co * 0.4 + (nb[0].co + nb[1].co) * 0.3
        for v, c in new.items():
            v.co = c
    bm.to_mesh(obj.data)
    bm.free()


def dominant(obj):
    """Per vertex dominant bone name."""
    names = {g.index: g.name for g in obj.vertex_groups}
    out = []
    for v in obj.data.vertices:
        best, bw = "hips", -1.0
        for g in v.groups:
            if g.weight > bw:
                best, bw = names[g.group], g.weight
        out.append(best)
    return out


def set_uv(obj, uv):
    """uv: per-vertex atlas uv (same order as the mesh vertices it was built with) - but
    meshes keep per-corner UVs, so this maps through loops."""
    me = obj.data
    lay = me.uv_layers.active
    for l in me.loops:
        lay.data[l.index].uv = tuple(uv[l.index])


def remap_obj_uvs(obj, rect, aw, ah):
    me = obj.data
    lay = me.uv_layers.active
    n = len(me.loops)
    a = np.zeros(n * 2)
    lay.data.foreach_get("uv", a)
    a = a.reshape(-1, 2)
    b = remap_uv(a, rect, aw, ah)
    lay.data.foreach_set("uv", b.ravel())
    return b


def const_uv(obj, patch):
    x, y, w, h = tile_rect("gear")
    cx, cy = GEAR_PATCHES[patch]
    u = (x + cx * w) / AW
    v = 1.0 - (y + cy * h) / AH
    me = obj.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    lay = me.uv_layers.active
    for l in me.loops:
        lay.data[l.index].uv = (u, v)


def decimate(obj, ratio):
    if ratio >= 0.999:
        return
    U.select_only(obj)
    md = obj.modifiers.new("dec", 'DECIMATE')
    md.ratio = ratio
    md.use_collapse_triangulate = False
    bpy.ops.object.modifier_apply(modifier=md.name)


# ------------------------------------------------------------------ gear shells (procedural, on the fitted body)
def safe_solidify(bm, thick):
    """Give an open shell thickness: an inward copy along vertex normals (no miter
    scaling, so folded rims can't spike like bmesh solidify) plus rim faces."""
    bm.normal_update()
    verts = list(bm.verts)
    faces = list(bm.faces)
    rim = [e for e in bm.edges if e.is_boundary]
    inner = {v: bm.verts.new(v.co - v.normal * thick) for v in verts}
    for f in faces:
        try:
            bm.faces.new([inner[v] for v in reversed(f.verts)])
        except ValueError:
            pass
    for e in rim:
        a, b = e.verts
        f = e.link_faces[0]
        # keep the winding consistent with the outer face that owns the edge
        loop = [l for l in f.loops if l.edge == e][0]
        if loop.vert != a:
            a, b = b, a
        try:
            bm.faces.new([b, a, inner[a], inner[b]])
        except ValueError:
            pass
    bm.normal_update()


def body_shell(body, name, keep, offset, thick=0.0):
    me = body.data.copy()
    me.name = name
    o = bpy.data.objects.new(name, me)
    U.link(o)
    dom = dominant(body)
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    dead = [f for f in bm.faces if not keep(f.calc_center_median(), f.normal, dom[f.verts[0].index])]
    bmesh.ops.delete(bm, geom=dead, context='FACES')
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context='VERTS')
    bm.normal_update()
    for v in bm.verts:
        v.co += v.normal * offset
    if thick > 0:
        safe_solidify(bm, thick)
    bm.to_mesh(me)
    bm.free()
    o.vertex_groups.clear()
    return o


def copy_weights(src, dst, only=None):
    kd = KDTree(len(src.data.vertices))
    for v in src.data.vertices:
        kd.insert(v.co, v.index)
    kd.balance()
    names = {g.index: g.name for g in src.vertex_groups}
    dst.vertex_groups.clear()
    groups = {}
    for v in dst.data.vertices:
        if only:
            items = [(only, 1.0)]
        else:
            _, i, _ = kd.find(v.co)
            items = [(names[g.group], g.weight) for g in src.data.vertices[i].groups]
        for b, w in items:
            if b not in groups:
                groups[b] = dst.vertex_groups.new(name=b)
            groups[b].add([v.index], w, 'REPLACE')


def make_gear(body, eyes, rig):
    """Hats, helmet, balaclava, sunglasses, vest, duty belt - built on the fitted body."""
    out = []
    co = np.array([v.co[:] for v in body.data.vertices])
    dom = dominant(body)
    head_v = co[[i for i, d in enumerate(dom) if d == "head"]]
    top = head_v[:, 2].max()
    hc = Vector(((0.0, (head_v[:, 1].min() + head_v[:, 1].max()) / 2, top - 0.115)))
    ec = np.array([v.co[:] for v in eyes.data.vertices])
    eye_z = float(ec[:, 2].mean())
    eye_y = float(ec[:, 1].min())
    eye_x = float(np.abs(ec[:, 0]).mean())

    def cap_keep(th_front, th_side, th_back, zmin):
        def fn(c, n, d):
            if d not in ("head", "neck") or c.z < zmin:
                return False
            v = (c - hc).normalized()
            f = -v.y
            thr = th_side + (th_front - th_side) * max(0.0, f) + (th_back - th_side) * max(0.0, -f)
            return v.z > thr
        return fn

    def fin(o, slot, patch, thick=0.0, bone="head", src=None):
        if thick:
            bm = bmesh.new()
            bm.from_mesh(o.data)
            safe_solidify(bm, thick)
            bm.to_mesh(o.data)
            bm.free()
        const_uv(o, patch)
        U.shade_smooth(o)
        copy_weights(src or body, o, bone)
        o["slot"] = slot
        out.append(o)
        return o

    z0 = eye_z + 0.015
    cap = body_shell(body, "cap", cap_keep(0.55, 0.22, 0.10, z0), 0.02)
    bm = bmesh.new()
    bm.from_mesh(cap.data)
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Matrix.Rotation(math.radians(10), 3, 'X') @ Vector((v.co.x * 0.17, v.co.y * 0.095, v.co.z * 0.008)) + Vector((0, eye_y - 0.045, eye_z + 0.055))
    bm.to_mesh(cap.data)
    bm.free()
    fin(cap, "hat", "fabric", 0.008)
    fin(body_shell(body, "beanie", cap_keep(0.48, 0.16, -0.05, z0 - 0.01), 0.018), "hat", "fabric", 0.01)
    fin(body_shell(body, "helmet", cap_keep(0.50, 0.02, -0.25, z0 - 0.04), 0.036), "gear", "fabric", 0.012)
    # police peaked cap: crown + top + visor + badge band
    bm = bmesh.new()
    res = bmesh.ops.create_cone(bm, cap_ends=True, segments=16, radius1=0.104, radius2=0.12, depth=0.075)
    for v in res["verts"]:
        v.co = Vector((v.co.x, v.co.y * 1.12, v.co.z)) + Vector((0, hc.y + 0.004, top - 0.012))
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Matrix.Rotation(math.radians(18), 3, 'X') @ Vector((v.co.x * 0.15, v.co.y * 0.07, v.co.z * 0.008)) + Vector((0, eye_y - 0.03, top - 0.045))
    ph = U.mesh_from_bmesh("police_hat", bm)
    fin(ph, "hat", "fabric")
    # balaclava with an eye slit
    def mask_keep(c, n, d):
        if d not in ("head", "neck") or c.z < eye_z - 0.21:
            return False
        if c.y < eye_y + 0.06 and abs(c.z - eye_z) < 0.024 and abs(c.x) < eye_x + 0.045:
            return False
        return True
    fin(body_shell(body, "mask", mask_keep, 0.006), "gear", "fabric", 0.003)
    # sunglasses
    bm = bmesh.new()
    for s in (1, -1):
        res = bmesh.ops.create_cube(bm, size=1.0)
        for v in res["verts"]:
            v.co = Vector((v.co.x * 0.036, v.co.y * 0.006, v.co.z * 0.022)) + Vector((eye_x * s, eye_y - 0.012, eye_z))
        res = bmesh.ops.create_cube(bm, size=1.0)
        for v in res["verts"]:
            v.co = Vector((v.co.x * 0.004, v.co.y * 0.1, v.co.z * 0.006)) + Vector(((eye_x + 0.05) * s, eye_y + 0.04, eye_z + 0.006))
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Vector((v.co.x * 0.03, v.co.y * 0.005, v.co.z * 0.005)) + Vector((0, eye_y - 0.014, eye_z + 0.006))
    gl = U.mesh_from_bmesh("sunglasses", bm)
    fin(gl, "fixed", "glass")
    # tactical vest (torso band) and duty belt (waist band + holster)
    chest_z = [co[i, 2] for i, d in enumerate(dom) if d == "chest"]
    hips_z = [co[i, 2] for i, d in enumerate(dom) if d == "hips"]
    z_top = float(np.percentile(chest_z, 88))
    z_waist = float(np.percentile(hips_z, 80))
    vest = body_shell(body, "vest", lambda c, n, d: d in ("chest", "spine", "hips") and z_waist + 0.03 < c.z < z_top and abs(c.x) < 0.19, 0.03, 0.02)
    fin(vest, "gear", "fabric", 0.0, None)
    belt = body_shell(body, "duty_belt", lambda c, n, d: d in ("hips", "spine") and abs(c.z - (z_waist + 0.0)) < 0.035, 0.022, 0.012)
    bm = bmesh.new()
    bm.from_mesh(belt.data)
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Vector((v.co.x * 0.05, v.co.y * 0.035, v.co.z * 0.14)) + Vector((-0.2, 0.0, z_waist - 0.06))
    bm.to_mesh(belt.data)
    bm.free()
    fin(belt, "gear", "black", 0.0, None)
    return out


# ------------------------------------------------------------------ one gender
def build_gender(gk, alb, hair_img, alb_img):
    G = GENDERS[gk]
    t0 = time.time()
    U.reset()
    bv = mh.morph(G["params"])
    B = mh.base()
    blb = mh.to_bl(bv)
    body_idx = B["gverts"]["body"]
    ground = blb[body_idx, 2].min()
    hipz = mh.to_bl(mh.bone_head(bv, "upperleg01.L"))[2] - ground
    S = HIP_Z / hipz
    real_scale = G["height"] / ((blb[body_idx, 2].max() - ground) * S)

    def W(v):
        p = mh.to_bl(v)
        p[:, 2] -= ground
        return p * S

    bw = mh.base_weights(map_bone)
    parts = {}
    meta = {}
    # --- body (+ eyes as a separate fixed part)
    px = mh.load_proxy(mh.path("proxymeshes", G["proxy"], G["proxy"] + ".proxy"))
    pob = mh.load_obj(px["obj_file"])
    body = mh_bl.mesh_from("body", W(mh.fit(px, bv)), pob)
    add_weights(body, mh.proxy_weights(px, bw))
    body_refs = (px["refs"], px["w"])
    remap_obj_uvs(body, tile_rect(G["skins"][0]), AW, AH)
    parts["body"] = body
    meta["body"] = {"slot": SLOT["skin"], "kind": "body"}
    epx, eob, emat = mh_bl.asset("eyes", "low-poly")
    eyes = mh_bl.mesh_from("eyes", W(mh.fit(epx, bv)), eob)
    add_weights(eyes, mh.proxy_weights(epx, bw))
    remap_obj_uvs(eyes, tile_rect("eyes"), AW, AH)
    parts["eyes"] = eyes
    # player / partner skin: the reference sheet's face projected onto this head
    if os.path.exists(os.path.join(REFS, HEROES[gk]["image"])):
        teeth = B["gverts"]["helper-upper-teeth"] + B["gverts"]["helper-lower-teeth"]
        mouth = W(bv[teeth]).mean(0)
        tile = project_face(gk, G["skins"][0], W(mh.fit(px, bv)), pob, np.array([v.co[:] for v in eyes.data.vertices]), mouth)
        x, y, w_, h_ = tile_rect(HEROES[gk]["tile"])
        alb_img.paste(tile.resize((w_, h_)), (x, y))
    meta["eyes"] = {"slot": SLOT["fixed"], "kind": "eyes"}
    if gk == "f":
        ea = mh_bl.mesh_from("eyes_alt", W(mh.fit(epx, bv)), eob)
        add_weights(ea, mh.proxy_weights(epx, bw))
        remap_obj_uvs(ea, tile_rect("eyes_f"), AW, AH)
        parts["eyes_alt"] = ea
        meta["eyes_alt"] = {"slot": SLOT["fixed"], "kind": "eyes"}
    # --- garments (split into parts), coverage of the body per part
    covers = {}      # part -> set(body vertex idx)
    bodyco = np.array([v.co[:] for v in body.data.vertices])
    for gname, classes in G["suits"].items():
        gpx, gob, gmat = mh_bl.asset("clothes", gname)
        gpos = W(mh.fit(gpx, bv))
        o = mh_bl.mesh_from(gname, gpos, gob)
        add_weights(o, mh.proxy_weights(gpx, bw))
        decimate(o, G["decimate"].get(gname, 1.0))
        uvs = remap_obj_uvs(o, tile_rect(gname), AW, AH)
        dom = dominant(o)
        isl = islands(o)
        groups = {"top": [], "bottom": []}
        for faces in isl:
            vs = set()
            for fi in faces:
                vs.update(o.data.polygons[fi].vertices)
            t = sum(1 for v in vs if dom[v] in TOP_BONES)
            b = sum(1 for v in vs if dom[v] in BOTTOM_BONES)
            groups["top" if t >= b else "bottom"] += faces
        hidden = set(i for i, (r, w) in enumerate(zip(*body_refs)) if all((r[k] in gpx["delete"]) or w[k] <= 0 for k in range(3)))
        variants = [(cls, pname, None) for cls, pname in classes.items()]
        if G.get("tank_from") in classes.values():
            cls = [c for c, p in classes.items() if p == G["tank_from"]][0]
            variants.append((cls, "tank", "sleeveless"))
        for cls, pname, mod in variants:
            faces = groups[cls]
            if not faces:
                continue
            p = o.copy()
            p.data = o.data.copy()
            p.name = pname
            U.link(p)
            if mod == "sleeveless":
                dom2 = dominant(o)
                faces = [fi for fi in faces if sum(1 for v in o.data.polygons[fi].vertices if dom2[v].startswith(("upper_arm", "forearm"))) < 2]
            keep_faces(p, faces)
            if mod == "sleeveless":
                relax_boundary(p, lambda co: abs(co.x) > 0.07, 8)
            # body verts this part covers: hidden by the garment and closest to this part
            kd = KDTree(len(p.data.vertices))
            for v in p.data.vertices:
                kd.insert(v.co, v.index)
            kd.balance()
            cov = set()
            bdom = dominant(body)
            for i in hidden:
                if mod == "sleeveless" and bdom[i].startswith(("upper_arm", "forearm", "shoulder")):
                    continue
                _, _, d = kd.find(Vector(bodyco[i]))
                if d is not None and d < 0.045:
                    cov.add(i)
            covers[pname] = cov
            parts[pname] = p
            pu = np.zeros(len(p.data.loops) * 2)
            p.data.uv_layers.active.data.foreach_get("uv", pu)
            meta[pname] = {"slot": SLOT[cls], "kind": cls, "lum": mean_lum(alb, pu.reshape(-1, 2)), "source": gname}
        bpy.data.objects.remove(o)
    for pname, m in list(meta.items()):
        if m.get("kind") == "bottom":
            flare_hems(parts[pname])
    for gname, pname in G["shoes"].items():
        gpx, gob, gmat = mh_bl.asset("clothes", gname)
        o = mh_bl.mesh_from(pname, W(mh.fit(gpx, bv)), gob)
        add_weights(o, mh.proxy_weights(gpx, bw))
        decimate(o, SHOE_DECIMATE)
        uvs = remap_obj_uvs(o, tile_rect(gname), AW, AH)
        hidden = set(i for i, (r, w) in enumerate(zip(*body_refs)) if all((r[k] in gpx["delete"]) or w[k] <= 0 for k in range(3)))
        covers[pname] = hidden
        parts[pname] = o
        meta[pname] = {"slot": SLOT["shoes"], "kind": "shoes", "lum": mean_lum(alb, uvs), "source": gname}
    # --- hair, brows, lashes (alpha atlas)
    for hname, pname in G["hairs"].items():
        hpx, hob, hmat = mh_bl.asset("hair", hname)
        o = mh_bl.mesh_from("hair_" + pname, W(mh.fit(hpx, bv)), hob)
        add_weights(o, mh.proxy_weights(hpx, bw))
        uvs = remap_obj_uvs(o, hair_rect(hname), 4096, 2048)
        parts["hair_" + pname] = o
        meta["hair_" + pname] = {"slot": SLOT["hair"], "kind": "hair", "lum": mean_lum(hair_img, uvs, True)}
    fh = []
    for kind, asset, rect in (("eyebrows", "eyebrow001", "brows"), ("eyelashes", "eyelashes01", "lashes")):
        hpx, hob, hmat = mh_bl.asset(kind, asset)
        o = mh_bl.mesh_from(kind, W(mh.fit(hpx, bv)), hob)
        add_weights(o, mh.proxy_weights(hpx, bw))
        remap_obj_uvs(o, hair_rect(rect), 4096, 2048)
        fh.append(o)
    lashes = fh[1].copy()
    lashes.data = fh[1].data.copy()
    U.link(lashes)
    lashes.name = "eyelashes"
    parts["eyelashes"] = lashes
    meta["eyelashes"] = {"slot": SLOT["hair"], "kind": "face_hair", "lum": 0.2}
    face_hair = U.join(fh, "face_hair")
    parts["face_hair"] = face_hair
    meta["face_hair"] = {"slot": SLOT["hair"], "kind": "face_hair", "lum": 0.2}
    print(gk, "parts fitted", round(time.time() - t0, 1), "s", {k: len(v.data.polygons) for k, v in parts.items()})

    # --- rig, rest-pose normalisation
    jts = {}
    for n, (h, t) in rig_joints(bv).items():
        jts[n] = ((np.array(h) - [0, 0, ground]) * S, (np.array(t) - [0, 0, ground]) * S)
    rig = build_rig(jts)
    meshes = list(parts.values())
    for m in meshes:
        arm_mod(m, rig)
    normalise_pose(rig, meshes)
    # re-ground after straightening the legs
    lowest = min(min((m.matrix_world @ v.co).z for v in m.data.vertices) for m in (parts["body"],))
    for o in meshes + [rig]:
        o.location.z -= lowest
    for o in meshes + [rig]:
        U.select_only(o)
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
    for m in meshes:
        arm_mod(m, rig)
    # --- gear shells on the final body
    gear = make_gear(parts["body"], parts["eyes"], rig)
    for g in gear:
        parts[g.name] = g
        meta[g.name] = {"slot": SLOT[g["slot"]], "kind": "gear" if g["slot"] == "gear" else g["slot"], "lum": 0.8 if g.name not in ("sunglasses",) else 0.05}
        arm_mod(g, rig)
    # --- body coverage masks -> vertex colour bytes (32 bits); bits per covering part
    bits = {}
    for i, pname in enumerate(sorted(covers)):
        bits[pname] = i
        meta[pname]["bit"] = i
    assert len(bits) <= 32, bits
    mask = np.zeros(len(parts["body"].data.vertices), dtype=np.uint32)
    for pname, cov in covers.items():
        for i in cov:
            mask[i] |= np.uint32(1 << bits[pname])
    me = parts["body"].data
    ca = me.color_attributes.new("Mask", 'FLOAT_COLOR', 'CORNER')
    for l in me.loops:
        m = int(mask[l.vertex_index])
        ca.data[l.index].color = ((m & 255) / 255.0, ((m >> 8) & 255) / 255.0, ((m >> 16) & 255) / 255.0, ((m >> 24) & 255) / 255.0)
    me.color_attributes.active_color = ca
    for o in meshes + gear:
        for p in o.data.polygons:
            p.use_smooth = True
    joints = {b.name: [round(x, 4) for x in b.head_local] for b in rig.data.bones}
    print(gk, "rig + gear", round(time.time() - t0, 1), "s; hips", joints["hips"], "ankle", joints["foot.L"])
    return rig, parts, meta, real_scale


def animate(rig):
    """Build every clip on this rig (IK authoring helpers added, baked, removed)."""
    # authoring helpers relative to this rig's joints
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = rig.data.edit_bones
    for s, sx in (("L", 1), ("R", -1)):
        knee = eb["shin." + s].head.copy()
        elbow = eb["forearm." + s].head.copy()
        for nm, h, t in (("foot_ik." + s, eb["foot." + s].head, eb["foot." + s].tail), ("knee_pole." + s, knee + Vector((0, -0.55, 0)), knee + Vector((0, -0.6, 0))),
                         ("hand_ik." + s, eb["hand." + s].head, eb["hand." + s].tail), ("elbow_pole." + s, elbow + Vector((0.06 * sx, 0.45, 0)), elbow + Vector((0.06 * sx, 0.5, 0)))):
            b = eb.new(nm)
            b.head = h.copy()
            b.tail = t.copy()
            b.use_deform = False
    ank = eb["foot.L"].head.copy()
    ball = eb["toe.L"].head.copy()
    bpy.ops.object.mode_set(mode='OBJECT')
    # the gait generator's foot geometry comes from this rig
    HA.ANKLE = Vector(ank)
    HA.BALL = Vector(ball)
    HA.HEEL = Vector((ank.x, ank.y + 0.045, 0.012))
    HA.HIP_Z = rig.data.bones["hips"].head_local.z
    HL.ANKLE = HA.ANKLE
    HA.setup_ik(rig)
    # finger / thumb tips follow the main curl bone (two extra knuckles = natural curl)
    pb = rig.pose.bones
    for s in ("L", "R"):
        for nm, src, inf in (("fingers_mid." + s, "fingers." + s, 0.9), ("fingers_tip." + s, "fingers." + s, 0.7), ("thumb_tip." + s, "thumb." + s, 0.8)):
            c = pb[nm].constraints.new('COPY_ROTATION')
            c.target = rig
            c.subtarget = src
            c.target_space = 'LOCAL'
            c.owner_space = 'LOCAL'
            c.mix_mode = 'REPLACE'
            c.influence = inf
    A = HA.Animator(rig)
    clips = HL.build_all(A)
    for p in rig.pose.bones:
        for c in list(p.constraints):
            p.constraints.remove(c)
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='EDIT')
    for b in list(rig.data.edit_bones):
        if not b.use_deform:
            rig.data.edit_bones.remove(b)
    bpy.ops.object.mode_set(mode='OBJECT')
    # prop sockets: pistol grip (aim pose) and phone (phone pose)
    aim = bpy.data.actions["aim_idle"]
    rig.animation_data.action = aim
    bpy.context.scene.frame_set(0)
    bpy.context.view_layer.update()
    hm = rig.pose.bones["hand.R"].matrix
    palm = hm.translation + hm.col[1].xyz * 0.055
    MHU.add_prop_bone(rig, "weapon.R", "hand.R", aim, 0, MHU.frame_from(palm + Vector((0, 0, 0.02)), (0.02, -1, 0.02), (0, 0, 1)))
    ph = bpy.data.actions["phone"]
    rig.animation_data.action = ph
    bpy.context.scene.frame_set(20)
    bpy.context.view_layer.update()
    hm = rig.pose.bones["hand.R"].matrix
    palm = hm.translation + hm.col[1].xyz * 0.05
    MHU.add_prop_bone(rig, "prop.R", "hand.R", ph, 20, MHU.frame_from(palm, (0, 0.15, 1), (-1.0, -0.1, 0)))
    rig.animation_data.action = None
    for p in rig.pose.bones:
        p.location = (0, 0, 0)
        p.rotation_quaternion = (1, 0, 0, 0)
        p.rotation_euler = (0, 0, 0)
    return clips


def main():
    t0 = time.time()
    alb_img, nrm_img, hair_pil = build_atlases()
    alb = np.asarray(alb_img)
    hair_img = np.asarray(hair_pil)
    catalogue = {}
    for gk in GENDERS:
        rig, parts, meta, real_scale = build_gender(gk, alb, hair_img, alb_img)
        clips = animate(rig)
        mat = U.material("Human_" + gk, vcol=False)
        for nm, o in parts.items():
            o.data.materials.clear()
            o.data.materials.append(mat)
            o.parent = rig
            # cap influences at 4 for the GPU
            U.select_only(o)
            bpy.ops.object.vertex_group_limit_total(limit=4)
            bpy.ops.object.vertex_group_normalize_all(lock_active=False)
        out = os.path.join(MODELS, "human_%s.glb" % gk)
        U.export_glb(out, [rig] + list(parts.values()))
        skins = {}
        base = tile_rect(GENDERS[gk]["skins"][0])
        for s in GENDERS[gk]["skins"]:
            r = tile_rect(s)
            skins[s] = [(r[0] - base[0]) / AW, (r[1] - base[1]) / AH]
        r = tile_rect(HEROES[gk]["tile"])
        skins[HEROES[gk]["tile"]] = [(r[0] - base[0]) / AW, (r[1] - base[1]) / AH]
        catalogue[gk] = {"parts": meta, "skins": skins, "scale": round(real_scale, 4), "height": GENDERS[gk]["height"], "clips": len(clips)}
        print(gk, "exported", os.path.getsize(out) // 1024, "KB,", len(clips), "clips,", round(time.time() - t0, 1), "s")
        if "--preview" in sys.argv:
            bpy.ops.wm.save_as_mainfile(filepath="/tmp/mh_%s.blend" % gk)
    save_atlases(alb_img, nrm_img, hair_pil)
    with open(os.path.join(CHARS, "humans.json"), "w") as f:
        json.dump(catalogue, f, indent=1)
    print("done", round(time.time() - t0, 1), "s")


if __name__ == "__main__":
    main()
