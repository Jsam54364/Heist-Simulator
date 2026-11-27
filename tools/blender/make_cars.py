"""Vehicle models: python tools/blender/make_cars.py  ->  assets/models/cars.glb + cars.json

Every body is lofted from cross-section stations (front to back: bumper, hood, cowl,
windshield, roof, rear glass, trunk/tail) taken from real proportions for the class, then
subdivided once, wheel arches cut with booleans, door seams pressed in, and dressed with
lights, grille, bumpers, plates, mirrors, handles, an interior (lining, seats, dash and a
steering wheel placed where the seated driver's hands are) and class extras (taxi sign,
police light bar + push bar + door decals, pickup bed, armoured box bodies).

Surfaces (named materials the game swaps): Paint (per-car colour, vertex colour = panel AO /
seams), Glass, Parts (one shared shader: vertex colour = sRGB colour, alpha = emission class
0 / 0.5 headlight / 1 tail light, UV2 = roughness, metal), Decal (police lettering).
Coordinates are written in Godot space (x left, y up, z forward) and converted.
"""
import os
import sys
import json
import math
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy
import bmesh
from mathutils import Vector, Matrix
import bl_util as U

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "assets", "models", "cars.glb")
WHEEL_R = 0.36

# measured on the "drive" clip, relative to the hip joint (up, forward)
WHEEL_FROM_HIPS = (0.215, 0.44)           # steering wheel centre between the hands
ANKLE_FROM_HIPS = (-0.242, 0.752)


def recline_pt(p, deg):
    """(up, forward) offset from the hips after leaning the seated body back by deg."""
    r = math.radians(deg)
    up, fw = p
    return (up * math.cos(r) + fw * math.sin(r), fw * math.cos(r) - up * math.sin(r))


def G(x, y, z):
    return Vector((x, -z, y))


# ------------------------------------------------------------------ mesh builder
class B:
    """bmesh accumulator with face materials, sRGB colour + emission class, and RM uv."""
    MATS = ["Paint", "Glass", "Parts", "Decal"]

    def __init__(self):
        self.bm = bmesh.new()
        self.col = self.bm.loops.layers.float_color.new("Col")
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.rm = self.bm.loops.layers.uv.new("RM")

    def face(self, pts, mat="Parts", col=(0.1, 0.1, 0.1), em=0.0, rough=0.6, metal=0.0, uvs=None):
        vs = [self.bm.verts.new(G(*p) if not isinstance(p, Vector) else p) for p in pts]
        try:
            f = self.bm.faces.new(vs)
        except ValueError:
            return None
        f.material_index = self.MATS.index(mat)
        for i, l in enumerate(f.loops):
            l[self.col] = (col[0], col[1], col[2], em)
            l[self.rm].uv = (rough, 1.0 - metal)
            if uvs:
                l[self.uv].uv = uvs[i]
        return f

    def box(self, c, size, mat="Parts", col=(0.1, 0.1, 0.1), em=0.0, rough=0.6, metal=0.0, rot=None, bevel=0.0):
        x, y, z = (s / 2 for s in size)
        P = [(-x, -y, -z), (x, -y, -z), (x, y, -z), (-x, y, -z), (-x, -y, z), (x, -y, z), (x, y, z), (-x, y, z)]
        R = rot if rot is not None else Matrix.Identity(3)
        P = [Vector(c) + R @ Vector(p) for p in P]
        for idx in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (2, 3, 7, 6), (1, 2, 6, 5), (3, 0, 4, 7)):
            self.face([tuple(P[i]) for i in idx], mat, col, em, rough, metal)

    def cyl(self, c, axis, r, depth, seg=16, mat="Parts", col=(0.1, 0.1, 0.1), em=0.0, rough=0.6, metal=0.0, caps=True):
        a = Vector(axis).normalized()
        u = a.orthogonal().normalized()
        v = a.cross(u)
        c = Vector(c)
        ring0 = [c - a * depth / 2 + (u * math.cos(t) + v * math.sin(t)) * r for t in (i * 2 * math.pi / seg for i in range(seg))]
        ring1 = [p + a * depth for p in ring0]
        for i in range(seg):
            j = (i + 1) % seg
            self.face([tuple(ring0[i]), tuple(ring0[j]), tuple(ring1[j]), tuple(ring1[i])], mat, col, em, rough, metal)
        if caps:
            self.face([tuple(p) for p in reversed(ring0)], mat, col, em, rough, metal)
            self.face([tuple(p) for p in ring1], mat, col, em, rough, metal)

    def obj(self, name):
        bmesh.ops.remove_doubles(self.bm, verts=self.bm.verts[:], dist=1e-5)
        me = bpy.data.meshes.new(name)
        self.bm.to_mesh(me)
        self.bm.free()
        o = bpy.data.objects.new(name, me)
        U.link(o)
        for m in self.MATS:
            o.data.materials.append(MAT[m])
        ca = me.color_attributes.get("Col")
        if ca:
            me.color_attributes.active_color = ca
        return o


MAT = {}


def materials():
    for n, c in (("Paint", (0.8, 0.1, 0.1, 1)), ("Glass", (0.1, 0.12, 0.14, 0.4)), ("Parts", (0.2, 0.2, 0.2, 1)), ("Decal", (1, 1, 1, 1))):
        m = bpy.data.materials.new(n)
        m.diffuse_color = c
        MAT[n] = m


# ------------------------------------------------------------------ body loft
# ------------------------------------------------------------------ body loft
def interp(keys, z):
    """Linear interpolation of station tuples along z (keys sorted front -> back)."""
    for a, b in zip(keys, keys[1:]):
        if a[0] >= z >= b[0]:
            t = (a[0] - z) / max(1e-6, a[0] - b[0])
            return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))
    return keys[0] if z > keys[0][0] else keys[-1]


def is_cab(st):
    return st[3] > st[2] + 0.04


def ring(st):
    """Cross-section (x >= 0 half, bottom centre -> top centre) for station (z, b, s, r, hw, rw).
    Bands between points: 0 floor, 1 rocker, 2 door, 3 shoulder, 4 side window / hood edge,
    5 roof rail (A/C pillar line), 6 roof / glass."""
    z, b, s, r, hw, rw = st
    pts = [(0.0, b), (hw - 0.1, b), (hw, b + 0.13), (hw, s - 0.1), (hw - 0.03, s)]
    if is_cab(st):
        pts += [(rw, r - 0.07), (rw - 0.09, r - 0.005), (0.0, r + 0.012)]
    else:
        pts += [(hw - 0.12, s + 0.018), (hw * 0.5, s + 0.034), (0.0, s + 0.04)]
    return pts


def inside(rng, z):
    return rng is not None and rng[0] >= z >= rng[1]


def loft(spec):
    """Body shell lofted through the stations. Paint vertex colour darkens door shut lines;
    glass bands come from the windshield / rear window / side window ranges."""
    keys = spec["keys"]
    seams = spec.get("seams", ())
    bp = spec.get("bpillar")
    zf, zb = keys[0][0], keys[-1][0]
    zs = set(k[0] for k in keys)
    n = int((zf - zb) / 0.16)
    zs.update(zf - (zf - zb) * i / n for i in range(n + 1))
    for sz in seams:
        zs.update((sz + 0.006, sz - 0.006))
    if bp is not None:
        zs.update((bp + 0.05, bp - 0.05))
    zs = sorted(zs, reverse=True)
    b = B()
    bm = b.bm
    rings = []
    for z in zs:
        st = (z,) + interp(keys, z)[1:]
        pts = ring(st)
        right = [bm.verts.new(G(-x, y, z)) for x, y in pts]
        left = [bm.verts.new(G(x, y, z)) for x, y in reversed(pts[1:-1])]
        rings.append((st, right + left))
    N = len(rings[0][1])
    half = len(ring(keys[0]))
    seam_z = [(sz + 0.006, sz - 0.006) for sz in seams]
    for i in range(len(rings) - 1):
        (st0, v0), (st1, v1) = rings[i], rings[i + 1]
        zm = (st0[0] + st1[0]) / 2
        cab = is_cab(st0) and is_cab(st1)
        in_seam = any(a >= zm >= c for a, c in seam_z)
        tonneau = spec.get("tonneau") is not None and zm < spec["tonneau"]
        for j in range(N):
            k = (j + 1) % N
            f = bm.faces.new((v0[j], v0[k], v1[k], v1[j]))
            band = j if j < half - 1 else (N - 1 - j)
            mat, col, rough, metal = "Paint", (1.0, 1.0, 1.0), 0.3, 0.5
            if band == 0:
                mat, col, rough, metal = "Parts", (0.03, 0.03, 0.035), 0.9, 0.0
            elif band == 1:
                col = (0.82, 0.82, 0.82)
            elif band in (2, 3) and in_seam:
                col = (0.16, 0.16, 0.16)
            elif band == 4 and cab:
                if bp is not None and abs(zm - bp) < 0.05:
                    mat, col, rough, metal = "Parts", (0.02, 0.02, 0.022), 0.35, 0.0     # blacked B pillar
                elif inside(spec.get("side_glass"), zm):
                    mat = "Glass"
                elif in_seam:
                    col = (0.16, 0.16, 0.16)
            elif band == 6 and cab and (inside(spec.get("wind"), zm) or inside(spec.get("rear"), zm)):
                mat = "Glass"
            elif band in (5, 6) and tonneau:
                mat, col, rough, metal = "Parts", (0.025, 0.025, 0.028), 0.75, 0.0       # bed cover
            f.material_index = B.MATS.index(mat)
            for l in f.loops:
                l[b.col] = (col[0], col[1], col[2], 0.0)
                l[b.rm].uv = (rough, 1.0 - metal)
    for vr in (rings[0][1], rings[-1][1]):
        f = bm.faces.new(vr)
        for l in f.loops:
            l[b.col] = (1.0, 1.0, 1.0, 0.0)
            l[b.rm].uv = (0.3, 0.5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return b.obj("shell")


def subdivide(o, levels=1):
    U.select_only(o)
    m = o.modifiers.new("sub", 'SUBSURF')
    m.levels = levels
    m.render_levels = levels
    bpy.ops.object.modifier_apply(modifier=m.name)


def arch_cut(o, wheels, W, r=0.43, depth=0.34):
    """Boolean-cut wheel arches; the cutter's faces stay behind as dark wheel-well liners."""
    b = B()
    for (sx, z) in wheels:
        b.cyl((sx * (W / 2 - depth / 2 + 0.05), WHEEL_R, z), (1, 0, 0), r, depth + 0.1, seg=28, col=(0.02, 0.02, 0.02), rough=0.95)
    cut = b.obj("cut")
    for p in cut.data.polygons:
        p.material_index = 2
    U.select_only(o)
    m = o.modifiers.new("arch", 'BOOLEAN')
    m.operation = 'DIFFERENCE'
    m.object = cut
    m.solver = 'EXACT'
    try:
        m.material_mode = 'TRANSFER'
    except Exception:
        pass
    bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.data.objects.remove(cut)
    bpy.context.view_layer.update()


def liner(o, spec):
    """Dark cabin lining: an inset, inward-facing copy of the cabin's painted panels, so the
    windows show an interior (door cards, headliner, pillars) instead of the world behind."""
    keys = spec["keys"]
    cz = [k[0] for k in keys if is_cab(k)]
    z0, z1 = max(cz) + 0.3, min(cz) - 0.05
    floor = min(k[1] for k in keys) + 0.06
    me = o.data.copy()
    li = bpy.data.objects.new("liner", me)
    U.link(li)
    bm = bmesh.new()
    bm.from_mesh(me)
    paint = B.MATS.index("Paint")
    dead = []
    for f in bm.faces:
        c = f.calc_center_median()
        gz, gy = -c.y, c.z
        if f.material_index != paint or not (z0 >= gz >= z1) or gy < floor:
            dead.append(f)
    bmesh.ops.delete(bm, geom=dead, context='FACES')
    bm.normal_update()
    for v in bm.verts:
        v.co -= v.normal * 0.03
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    col = bm.loops.layers.float_color.get("Col")
    rm = bm.loops.layers.uv.get("RM")
    for f in bm.faces:
        f.material_index = 2
        hi = f.calc_center_median().z > spec["keys"][0][2] + 0.25
        c = (0.16, 0.155, 0.15) if hi else (0.07, 0.07, 0.075)      # light headliner, dark door cards
        for l in f.loops:
            l[col] = (c[0], c[1], c[2], 0.0)
            l[rm].uv = (0.9, 1.0)
    bm.to_mesh(me)
    bm.free()
    return li


# ------------------------------------------------------------------ dressing
def lights_and_trim(b, spec):
    L, W = spec["L"], spec["W"]
    keys = spec["keys"]
    hw = W / 2
    zf, zr = keys[0][0], keys[-1][0]
    hy = min(interp(keys, zf - 0.1)[2] - 0.07, spec["light_y"])
    ty = interp(keys, zr + 0.1)[2] - 0.09
    fy = spec["front_y"]
    ry = keys[-1][1] + 0.08
    for sx in (1, -1):
        # headlight: lens + inner projector, amber indicator outboard
        wrap = Matrix.Rotation(math.radians(sx * 16), 3, 'Y')
        b.box((sx * (hw - 0.24), hy, zf - 0.08), (0.44, 0.095, 0.14), col=(0.05, 0.05, 0.055), rough=0.3, rot=wrap)
        b.box((sx * (hw - 0.27), hy + 0.005, zf - 0.06), (0.3, 0.06, 0.14), col=(1.0, 0.97, 0.88), em=0.5, rough=0.1, rot=wrap)
        b.box((sx * (hw - 0.27), hy - 0.035, zf - 0.06), (0.3, 0.012, 0.15), col=(1.0, 0.98, 0.95), em=0.5, rough=0.1, rot=wrap)
        b.box((sx * (hw - 0.07), hy, zf - 0.17), (0.08, 0.06, 0.12), col=(1.0, 0.55, 0.1), rough=0.2, rot=wrap)
        # tail light + reverse lamp
        b.box((sx * (hw - 0.22), ty, zr + 0.05), (0.36, 0.13, 0.1), col=(0.85, 0.05, 0.04), em=1.0, rough=0.15)
        b.box((sx * (hw - 0.47), ty, zr + 0.04), (0.12, 0.08, 0.1), col=(0.95, 0.95, 0.95), rough=0.15)
        # fog lamps
        b.box((sx * (hw - 0.22), fy + 0.02, zf + 0.02), (0.12, 0.06, 0.04), col=(1.0, 0.97, 0.9), rough=0.1)
    gw = spec.get("grille_w", W * 0.4)
    b.box((0, hy - 0.01, zf - 0.03), (gw, 0.15, 0.08), col=(0.025, 0.025, 0.03), rough=0.45, metal=0.3)
    b.box((0, hy - 0.01, zf + 0.012), (gw + 0.04, 0.02, 0.02), col=(0.7, 0.71, 0.73), rough=0.2, metal=1.0)
    b.box((0, fy + 0.07, zf - 0.04), (W - 0.6, 0.09, 0.08), col=(0.03, 0.03, 0.035), rough=0.7)
    if spec.get("big") or spec.get("police"):
        b.box((0, fy, zf - 0.05), (W - 0.1, 0.1, 0.14), col=(0.06, 0.06, 0.065), rough=0.75)
        b.box((0, ry, zr + 0.05), (W - 0.1, 0.12, 0.14), col=(0.06, 0.06, 0.065), rough=0.75)
    else:
        b.box((0, fy - 0.03, zf - 0.09), (W - 0.3, 0.05, 0.12), col=(0.03, 0.03, 0.035), rough=0.7)
        b.box((0, ry - 0.03, zr + 0.09), (W - 0.3, 0.05, 0.12), col=(0.03, 0.03, 0.035), rough=0.7)
        b.box((0, ry + 0.22, zr - 0.0), (W - 0.7, 0.025, 0.02), col=(0.7, 0.71, 0.73), rough=0.2, metal=1.0)
    b.box((0, fy + 0.15, zf + 0.025), (0.52, 0.12, 0.012), col=(0.92, 0.92, 0.9), rough=0.4)
    b.box((0, ry + 0.16, zr - 0.025), (0.52, 0.12, 0.012), col=(0.92, 0.92, 0.9), rough=0.4)
    for sx in (1, -1):
        b.box((sx * 0.35, ry - 0.04, zr - 0.05), (0.07, 0.07, 0.12), col=(0.4, 0.4, 0.42), rough=0.3, metal=0.9) if sx > 0 else None


def mirrors_handles(b, spec):
    W = spec["W"]
    keys = spec["keys"]
    hw = W / 2
    zm = spec["mirror"]
    belt = interp(keys, zm)[2]
    for sx in (1, -1):
        b.box((sx * (hw + 0.075), belt + 0.09, zm), (0.15, 0.1, 0.07), mat="Paint", col=(1, 1, 1), rough=0.3, metal=0.5)
        b.box((sx * (hw + 0.075), belt + 0.09, zm - 0.036), (0.13, 0.08, 0.004), col=(0.55, 0.6, 0.65), rough=0.05, metal=1.0)
        b.box((sx * (hw - 0.02), belt + 0.05, zm + 0.01), (0.09, 0.05, 0.1), col=(0.03, 0.03, 0.035))
        for hz in spec["handles"]:
            b.box((sx * (hw + 0.006), interp(keys, hz)[2] - 0.08, hz), (0.02, 0.025, 0.14), col=(0.72, 0.72, 0.75), rough=0.25, metal=0.9)


def back_glass(b, z, y0, y1, hw):
    b.face([(hw, y0, z), (-hw, y0, z), (-hw, y1, z), (hw, y1, z)], mat="Glass", col=(1, 1, 1))


def interior(b, spec, seats, wc):
    W = spec["W"]
    keys = spec["keys"]
    hip, dz = spec["seat_y"], spec["drv_z"]
    heel = hip + recline_pt(ANKLE_FROM_HIPS, spec.get("recline", 0))[0] - 0.07
    floor_y = max(heel - 0.02, min(k[1] for k in keys) + 0.04)
    belt = interp(keys, dz + 0.85)[2]
    zr = min(s[2] for s in seats) - 0.45
    b.box((0, floor_y, (dz + 1.0 + zr) / 2), (W - 0.3, 0.04, dz + 1.0 - zr), col=(0.05, 0.05, 0.055), rough=0.95)
    # dash, cluster hood, centre console
    b.box((0, belt - 0.13, dz + 0.88), (W - 0.24, 0.2, 0.62), col=(0.06, 0.06, 0.065), rough=0.7)
    b.box((0.36, belt - 0.02, dz + 0.62), (0.34, 0.06, 0.14), col=(0.04, 0.04, 0.045), rough=0.6)
    b.box((0, floor_y + 0.18, dz + 0.25), (0.22, 0.32, 0.9), col=(0.05, 0.05, 0.055), rough=0.7)
    trim = (0.1, 0.095, 0.09)
    for (x, y, z) in seats:
        b.box((x, y - 0.14, z + 0.08), (0.5, 0.12, 0.52), col=trim, rough=0.85)
        rot = Matrix.Rotation(math.radians(-16), 3, 'X')
        b.box((x, y + 0.24, z - 0.2), (0.5, 0.66, 0.12), col=trim, rough=0.85, rot=rot)
        if interp(keys, z - 0.31)[3] - 0.1 > y + 0.75:
            b.box((x, y + 0.66, z - 0.31), (0.26, 0.18, 0.1), col=trim, rough=0.85, rot=rot)
        b.box((x, (y - 0.2 + floor_y) / 2, z + 0.06), (0.42, max(0.04, y - 0.2 - floor_y), 0.4), col=(0.04, 0.04, 0.04), rough=0.8)
    # steering wheel: rim, three spokes, hub and column, plane tilted 25 deg
    c = Vector(wc)
    tilt = Matrix.Rotation(math.radians(25 + spec.get("recline", 0)), 3, 'X')
    seg = 18
    for i in range(seg):
        a = i * 2 * math.pi / seg
        p = Vector((math.cos(a) * 0.18, math.sin(a) * 0.18, 0))
        b.box(tuple(c + tilt @ p), (0.03, 0.066, 0.032), col=(0.03, 0.03, 0.03), rough=0.6, rot=tilt @ Matrix.Rotation(a, 3, 'Z'))
    for a in (0.0, math.pi, -math.pi / 2):
        p = Vector((math.cos(a) * 0.09, math.sin(a) * 0.09, 0))
        b.box(tuple(c + tilt @ p), (0.11, 0.03, 0.015), col=(0.05, 0.05, 0.05), rot=tilt @ Matrix.Rotation(a, 3, 'Z'))
    b.box(tuple(c), (0.1, 0.09, 0.05), col=(0.05, 0.05, 0.05), rot=tilt)
    b.box(tuple(c + tilt @ Vector((0, 0, 0.17))), (0.07, 0.07, 0.3), col=(0.05, 0.05, 0.05), rot=tilt)


# ------------------------------------------------------------------ cars
CARS = {
    # keys: z, bottom, belt, roof, half width, roof half width   (front -> back)
    "sedan": dict(L=4.6, W=1.9, wb=2.7, seat_y=0.5, recline=6, drv_z=-0.22, rear_z=-1.05, keys=[
        (2.30, 0.38, 0.62, 0.62, 0.8, 0), (2.24, 0.31, 0.72, 0.72, 0.89, 0), (2.05, 0.23, 0.81, 0.81, 0.93, 0), (1.55, 0.23, 0.88, 0.88, 0.95, 0),
        (1.0, 0.23, 0.95, 0.96, 0.95, 0.8), (0.18, 0.23, 0.97, 1.43, 0.95, 0.73), (-0.95, 0.23, 0.97, 1.45, 0.95, 0.73), (-1.62, 0.23, 0.98, 1.05, 0.95, 0.8),
        (-2.05, 0.31, 0.97, 0.97, 0.93, 0), (-2.25, 0.35, 0.9, 0.9, 0.87, 0), (-2.30, 0.42, 0.8, 0.8, 0.8, 0)],
        seams=(0.95, -1.3), bpillar=-0.3, wind=(1.0, 0.18), rear=(-0.95, -1.62), side_glass=(0.98, -1.2),
        handles=(-0.12, -1.12), mirror=0.82, light_y=0.7, front_y=0.38),
    "coupe": dict(L=4.4, W=1.95, wb=2.6, seat_y=0.42, recline=12, drv_z=-0.4, rear_z=-1.25, keys=[
        (2.20, 0.33, 0.6, 0.6, 0.82, 0), (2.14, 0.27, 0.7, 0.7, 0.92, 0), (1.9, 0.21, 0.78, 0.78, 0.96, 0), (1.35, 0.21, 0.84, 0.84, 0.97, 0),
        (0.72, 0.21, 0.88, 0.89, 0.97, 0.8), (-0.15, 0.21, 0.9, 1.3, 0.97, 0.72), (-0.85, 0.21, 0.91, 1.31, 0.97, 0.72), (-1.8, 0.21, 0.92, 0.95, 0.97, 0.84),
        (-2.06, 0.28, 0.92, 0.92, 0.95, 0), (-2.18, 0.33, 0.86, 0.86, 0.88, 0), (-2.20, 0.39, 0.76, 0.76, 0.8, 0)],
        seams=(0.68, -0.95), wind=(0.72, -0.15), rear=(-0.85, -1.8), side_glass=(0.7, -1.05),
        handles=(-0.75,), mirror=0.55, light_y=0.66, front_y=0.33),
    "suv": dict(L=4.8, W=2.05, wb=2.9, seat_y=0.72, recline=3, drv_z=0.0, rear_z=-0.95, keys=[
        (2.40, 0.5, 0.86, 0.86, 0.86, 0), (2.34, 0.43, 0.98, 0.98, 0.97, 0), (2.15, 0.36, 1.08, 1.08, 1.0, 0), (1.6, 0.36, 1.15, 1.15, 1.02, 0),
        (1.25, 0.36, 1.18, 1.19, 1.02, 0.87), (0.55, 0.36, 1.2, 1.78, 1.02, 0.83), (-2.12, 0.36, 1.22, 1.8, 1.02, 0.83),
        (-2.34, 0.43, 1.22, 1.72, 1.01, 0.85), (-2.40, 0.5, 1.2, 1.66, 0.98, 0.84)],
        seams=(1.2, -1.25), bpillar=-0.2, wind=(1.25, 0.55), side_glass=(1.23, -2.0), back_glass=(1.32, 1.56, 0.68),
        handles=(0.05, -1.0), mirror=1.08, light_y=0.95, front_y=0.5),
    "pickup": dict(L=5.2, W=2.05, wb=3.2, seat_y=0.74, recline=3, drv_z=0.25, rear_z=-0.4, keys=[
        (2.60, 0.5, 0.88, 0.88, 0.86, 0), (2.54, 0.43, 1.0, 1.0, 0.97, 0), (2.35, 0.36, 1.1, 1.1, 1.0, 0), (1.8, 0.36, 1.15, 1.15, 1.02, 0),
        (1.38, 0.36, 1.18, 1.19, 1.02, 0.87), (0.76, 0.36, 1.2, 1.74, 1.02, 0.84), (-0.36, 0.36, 1.2, 1.75, 1.02, 0.84), (-0.5, 0.36, 1.2, 1.73, 1.0, 0.84),
        (-0.52, 0.36, 1.2, 1.2, 1.02, 0), (-2.52, 0.36, 1.2, 1.2, 1.02, 0), (-2.60, 0.47, 1.18, 1.18, 0.99, 0)],
        seams=(1.32, -0.53), wind=(1.38, 0.76), side_glass=(1.36, -0.4), tonneau=-0.53, cab_glass=(-0.525, 1.3, 1.6, 0.55),
        handles=(0.3,), mirror=1.2, light_y=0.98, front_y=0.5),
    "swat": dict(L=5.6, W=2.2, wb=3.4, seat_y=0.92, drv_z=1.05, rear_z=-0.5, keys=[
        (2.80, 0.56, 1.0, 1.0, 0.95, 0), (2.72, 0.5, 1.12, 1.12, 1.05, 0), (2.3, 0.5, 1.25, 1.25, 1.09, 0), (1.95, 0.5, 1.32, 1.33, 1.1, 1.0),
        (1.45, 0.5, 1.35, 2.3, 1.1, 0.99), (1.2, 0.5, 1.35, 2.46, 1.1, 1.0), (-2.74, 0.5, 1.35, 2.48, 1.1, 1.02), (-2.80, 0.56, 1.35, 2.42, 1.08, 1.0)],
        seams=(1.9, 0.75, -2.0), wind=(1.95, 1.45), side_glass=(1.9, 0.8), handles=(1.25,), mirror=1.75, light_y=1.0, front_y=0.56,
        big=True, rear_windows=(1.65, 1.95)),
    "truck": dict(L=6.4, W=2.4, wb=3.8, seat_y=1.18, drv_z=1.75, rear_z=1.2, keys=[
        (3.20, 0.62, 1.15, 1.15, 1.05, 0), (3.12, 0.56, 1.3, 1.3, 1.16, 0), (2.7, 0.56, 1.42, 1.42, 1.2, 0), (2.45, 0.56, 1.48, 1.49, 1.2, 1.08),
        (2.05, 0.56, 1.5, 2.42, 1.2, 1.08), (1.4, 0.56, 1.5, 2.45, 1.2, 1.1), (1.3, 0.56, 1.5, 2.9, 1.2, 1.18), (-3.15, 0.56, 1.5, 2.92, 1.2, 1.18),
        (-3.20, 0.62, 1.5, 2.85, 1.18, 1.16)],
        seams=(2.5, 1.32, -2.2), wind=(2.45, 2.05), side_glass=(2.42, 1.45), handles=(1.6,), mirror=2.35, light_y=1.1, front_y=0.62, big=True),
}
CARS["taxi"] = dict(CARS["sedan"], taxi=True)
_P = 1.0435        # police interceptor: stretched + widened sedan
CARS["police"] = dict(CARS["sedan"], L=4.8, W=1.95, wb=2.8, police=True,
                      keys=[(k[0] * _P, k[1], k[2], k[3], k[4] * 1.026, k[5] * 1.026) for k in CARS["sedan"]["keys"]],
                      seams=(0.99, -1.36), bpillar=-0.31, wind=(1.04, 0.19), rear=(-0.99, -1.69), side_glass=(1.02, -1.25),
                      handles=(-0.13, -1.17), mirror=0.86, drv_z=-0.23, rear_z=-1.1)


def build_car(kind, spec):
    L, W, wb = spec["L"], spec["W"], spec["wb"]
    keys = spec["keys"]
    shell = loft(spec)
    subdivide(shell, 1)
    wz = wb / 2
    arch_cut(shell, [(1, wz), (-1, wz), (1, -wz), (-1, -wz)], W, r=0.46 if spec.get("big") else 0.43)
    li = liner(shell, spec)
    b = B()
    lights_and_trim(b, spec)
    mirrors_handles(b, spec)
    hip, dz = spec["seat_y"], spec["drv_z"]
    seats = [(0.36, hip, dz), (-0.36, hip, dz)]
    if spec["rear_z"] < dz - 0.6:
        seats += [(0.36, hip + 0.02, spec["rear_z"]), (-0.36, hip + 0.02, spec["rear_z"])]
    up, fw = recline_pt(WHEEL_FROM_HIPS, spec.get("recline", 0))
    wc = (0.36, hip + up, dz + fw)
    interior(b, spec, seats, wc)
    zr = keys[-1][0]
    if spec.get("back_glass"):
        y0, y1, hw = spec["back_glass"]
        back_glass(b, zr - 0.006, y0, y1, hw)
    if spec.get("cab_glass"):
        z, y0, y1, hw = spec["cab_glass"]
        back_glass(b, z, y0, y1, hw)
    if spec.get("rear_windows"):
        y0, y1 = spec["rear_windows"]
        for sx in (1, -1):
            b.face([(sx * 0.62, y0, zr - 0.006), (sx * 0.18, y0, zr - 0.006), (sx * 0.18, y1, zr - 0.006), (sx * 0.62, y1, zr - 0.006)][::(1 if sx > 0 else -1)],
                   mat="Glass", col=(1, 1, 1))
        b.box((0, 1.4, zr - 0.01), (0.03, 1.7, 0.02), col=(0.02, 0.02, 0.02))
    if spec.get("tonneau") is not None:
        for sx in (1, -1):
            b.box((sx * (W / 2 - 0.05), 1.245, (spec["tonneau"] + zr) / 2), (0.08, 0.03, spec["tonneau"] - zr), col=(0.04, 0.04, 0.045), rough=0.6)
    if spec.get("taxi"):
        b.box((0, 1.52, -0.4), (0.62, 0.15, 0.24), col=(1.0, 0.82, 0.15), em=0.5, rough=0.3)
        b.box((0, 1.455, -0.4), (0.7, 0.03, 0.3), col=(0.05, 0.05, 0.05))
        for sx in (1, -1):
            # chequer strip along the doors
            for i in range(14):
                z = 0.85 - i * 0.14
                c = (0.02, 0.02, 0.02) if i % 2 == 0 else (0.95, 0.95, 0.95)
                b.box((sx * (W / 2 + 0.002), 0.72, z), (0.004, 0.07, 0.14), col=c, rough=0.4)
    bars = []
    if spec.get("police") or kind == "swat":
        z_bar = 1.3 if kind == "swat" else -0.35
        top = interp(keys, z_bar)[3] + 0.012
        b.box((0, top + 0.03, z_bar), (1.24, 0.05, 0.3), col=(0.04, 0.04, 0.04))
        for sx in (1, -1):
            b.box((sx * 0.5, top + 0.015, z_bar), (0.06, 0.04, 0.24), col=(0.04, 0.04, 0.04))
        for sx, nm, c in ((1, "bar_blue", (0.15, 0.3, 1.0)), (-1, "bar_red", (1.0, 0.1, 0.12))):
            bb = B()
            bb.box((sx * 0.3, top + 0.1, z_bar), (0.56, 0.1, 0.26), col=c, rough=0.2)
            o = bb.obj("%s_%s" % (kind, nm))
            bars.append(o)
    if spec.get("police"):
        zf = keys[0][0]
        for sx in (1, -1):
            b.box((sx * 0.32, 0.6, zf + 0.12), (0.06, 0.44, 0.06), col=(0.03, 0.03, 0.03))
            b.box((sx * 0.45, 0.62, zf + 0.06), (0.06, 0.06, 0.14), col=(0.03, 0.03, 0.03))
        b.box((0, 0.68, zf + 0.12), (0.72, 0.06, 0.06), col=(0.03, 0.03, 0.03))
        b.box((0, 0.5, zf + 0.12), (0.72, 0.06, 0.06), col=(0.03, 0.03, 0.03))
        b.box((0.97, 1.0, 0.78), (0.06, 0.1, 0.16), col=(0.6, 0.6, 0.62), rough=0.2, metal=0.9)       # spotlight
        hw = W / 2 + 0.004
        z0, z1, y0, y1 = 0.75, -0.85, 0.48, 0.84
        b.face([(hw, y0, z0), (hw, y0, z1), (hw, y1, z1), (hw, y1, z0)], mat="Decal", col=(1, 1, 1), uvs=[(0, 0), (1, 0), (1, 1), (0, 1)])
        b.face([(-hw, y0, z1), (-hw, y0, z0), (-hw, y1, z0), (-hw, y1, z1)], mat="Decal", col=(1, 1, 1), uvs=[(0, 0), (1, 0), (1, 1), (0, 1)])
    if kind == "truck":
        for y in (1.2, 2.1, 2.75):
            for sx in (1, -1):
                b.box((sx * 1.205, y, -0.9), (0.02, 0.05, 4.4), mat="Paint", col=(0.7, 0.7, 0.7), rough=0.4, metal=0.6)
        b.box((0, 1.7, zr - 0.01), (0.03, 2.0, 0.02), col=(0.03, 0.03, 0.03))
        for sx in (1, -1):
            b.box((sx * 0.3, 1.75, zr - 0.03), (0.04, 0.04, 0.05), col=(0.7, 0.7, 0.72), rough=0.25, metal=0.9)
        b.box((0, 0.5, zr - 0.15), (1.6, 0.06, 0.3), col=(0.2, 0.2, 0.21), rough=0.6, metal=0.8)       # rear step
    if kind == "swat":
        b.box((0, 0.66, keys[0][0] + 0.1), (1.9, 0.26, 0.12), col=(0.03, 0.03, 0.03))                # ram bumper
        b.box((0, 0.5, zr - 0.15), (1.4, 0.06, 0.3), col=(0.2, 0.2, 0.21), rough=0.6, metal=0.8)
    det = b.obj("details")
    U.select_only(li, det, shell)
    bpy.ops.object.join()
    shell.name = kind + "_body"
    shell.data.name = kind + "_body"
    U.select_only(shell)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(38))
    except Exception:
        bpy.ops.object.shade_smooth()
    return shell, bars, {"seats": [[round(c, 3) for c in s] for s in seats], "recline": spec.get("recline", 0), "wheel": [round(c, 3) for c in wc]}


def build_wheel():
    """Tyre with rounded shoulders + 5-spoke alloy, symmetric so one mesh serves both sides
    (it spins about x, so nothing fixed like a caliper belongs on it). Radius = WHEEL_R."""
    b = B()
    seg = 28
    prof = [(0.118, 0.26), (0.13, 0.3), (0.13, 0.33), (0.12, 0.352), (0.1, 0.36), (0.0, 0.361), (-0.1, 0.36), (-0.12, 0.352),
            (-0.13, 0.33), (-0.13, 0.3), (-0.118, 0.26)]
    rings = []
    for i in range(seg):
        a = i * 2 * math.pi / seg
        rings.append([(x, math.cos(a) * r, math.sin(a) * r) for x, r in prof])
    for i in range(seg):
        j = (i + 1) % seg
        for k in range(len(prof) - 1):
            tread = 4 <= k <= 5 and i % 2 == 0
            b.face([rings[i][k], rings[i][k + 1], rings[j][k + 1], rings[j][k]], col=(0.028, 0.028, 0.03) if tread else (0.04, 0.04, 0.042), rough=0.92)
    b.cyl((0, 0, 0), (1, 0, 0), 0.262, 0.2, seg=seg, col=(0.5, 0.51, 0.53), rough=0.3, metal=0.9, caps=False)
    for sx in (1, -1):
        b.cyl((sx * 0.085, 0, 0), (1, 0, 0), 0.25, 0.012, seg=seg, col=(0.06, 0.06, 0.065), rough=0.6)
        b.cyl((sx * 0.1, 0, 0), (1, 0, 0), 0.258, 0.016, seg=seg, col=(0.72, 0.73, 0.75), rough=0.22, metal=0.95, caps=False)
        b.cyl((sx * 0.1, 0, 0), (1, 0, 0), 0.075, 0.03, seg=12, col=(0.72, 0.73, 0.75), rough=0.22, metal=0.95)
        b.cyl((sx * 0.117, 0, 0), (1, 0, 0), 0.032, 0.006, seg=10, col=(0.1, 0.1, 0.11), rough=0.4)
        for k in range(5):
            a = k * 2 * math.pi / 5
            rot = Matrix.Rotation(a, 3, 'X')
            b.box(tuple(rot @ Vector((sx * 0.1, 0.0, 0.165))), (0.03, 0.055, 0.19), col=(0.72, 0.73, 0.75), rough=0.22, metal=0.95, rot=rot)
        # brake disc + caliper peeking through the spokes
        b.cyl((sx * 0.03, 0, 0), (1, 0, 0), 0.2, 0.025, seg=20, col=(0.35, 0.35, 0.36), rough=0.4, metal=0.8)
    return b.obj("wheel")


def build_heli():
    """Police helicopter (light single-engine type): lofted elliptical fuselage with a wrap-around
    cockpit glazing, engine cowling, tail boom, fins, skids, beacon and searchlight; the main
    rotor and the tail rotor are separate meshes so the game can spin them.
    Origin = fuselage centre; skids at y -1.35; main rotor hub at (0, 1.45, -0.2);
    tail rotor hub at (0.22, 0.95, -5.55). Everything uses the Parts / Glass materials."""
    b = B()
    navy, white, dark = (0.07, 0.12, 0.26), (0.92, 0.93, 0.95), (0.05, 0.05, 0.055)
    # z, y centre, half width, half height  (front -> back)
    st = [(2.45, -0.25, 0.08, 0.1), (2.3, -0.2, 0.42, 0.5), (1.9, -0.08, 0.72, 0.85), (1.3, 0.0, 0.86, 0.98), (0.4, 0.05, 0.9, 1.02),
          (-0.6, 0.08, 0.86, 0.98), (-1.3, 0.22, 0.6, 0.72), (-1.8, 0.42, 0.32, 0.4), (-1.95, 0.46, 0.24, 0.3)]
    n = 18
    rings = []
    for z, yc, hw, hh in st:
        rings.append([(hw * math.cos(2 * math.pi * i / n), yc + hh * math.sin(2 * math.pi * i / n), z) for i in range(n)])
    for r in range(len(rings) - 1):
        zm = (st[r][0] + st[r + 1][0]) / 2
        for i in range(n):
            j = (i + 1) % n
            t = math.degrees(2 * math.pi * (i + 0.5) / n)            # 0 = left side, 90 = top, 270 = belly
            up = math.sin(math.radians(t))
            side = abs(math.cos(math.radians(t)))
            mat, col, rough, metal = "Parts", navy, 0.35, 0.3
            if zm > 1.0 and up > -0.25 and not (up > 0.92 and zm < 1.6):
                mat, col = "Glass", white                                   # wrap-around canopy
            elif 1.0 >= zm > -0.5 and 0.15 < up < 0.75 and side > 0.5:
                mat, col = "Glass", white                                   # cabin doors
            elif -0.42 < up < -0.08:
                col = white                                                 # livery band
            elif up < -0.8:
                col = dark
            b.face([rings[r][i], rings[r][j], rings[r + 1][j], rings[r + 1][i]], mat=mat, col=col, rough=rough, metal=metal)
    b.face([p for p in rings[0]][::-1], col=navy)
    b.face(list(rings[-1]), col=navy)
    # engine cowling + exhaust + mast
    b.box((0, 1.13, -0.55), (0.9, 0.36, 1.9), col=navy, rough=0.4, metal=0.3)
    b.box((0, 1.12, -1.55), (0.5, 0.26, 0.4), col=(0.12, 0.12, 0.13), rough=0.5, metal=0.6)
    b.cyl((0, 1.38, -0.2), (0, 1, 0), 0.09, 0.26, seg=10, col=(0.25, 0.25, 0.27), rough=0.4, metal=0.8)
    # tail boom (tapered), fin, stabiliser, tail-rotor guard
    for k in range(6):
        z0, z1 = -1.9 - k * 0.62, -1.9 - (k + 1) * 0.62
        r0, r1 = 0.24 - k * 0.018, 0.24 - (k + 1) * 0.018
        b.cyl((0, 0.5 + 0.03 * k, (z0 + z1) / 2), (0, 0, 1), (r0 + r1) / 2, 0.64, seg=10, col=navy if k < 4 else white, rough=0.4, metal=0.3, caps=False)
    b.box((0, 1.05, -5.55), (0.08, 1.0, 0.55), col=navy, rough=0.4, rot=Matrix.Rotation(math.radians(-18), 3, 'X'))
    b.box((0, 0.6, -4.9), (1.5, 0.05, 0.38), col=navy, rough=0.4)
    for sx in (1, -1):
        b.box((sx * 0.75, 0.68, -4.9), (0.05, 0.25, 0.35), col=navy)
    # skids + struts
    for sx in (1, -1):
        b.cyl((sx * 0.95, -1.35, 0.15), (0, 0, 1), 0.05, 3.3, seg=8, col=dark, rough=0.5, metal=0.5)
        b.cyl((sx * 0.95, -1.27, 1.86), (0, 0.45, 1), 0.05, 0.3, seg=8, col=dark, rough=0.5, metal=0.5)
        for z in (0.95, -0.75):
            rot = Matrix.Rotation(math.radians(sx * 28), 3, 'Z')
            b.box((sx * 0.8, -1.05, z), (0.07, 0.65, 0.07), col=dark, rough=0.5, metal=0.5, rot=rot)
    # searchlight pod, landing light, beacons, step
    b.cyl((0.0, -1.0, 1.75), (0, 0, 1), 0.14, 0.3, seg=12, col=(0.15, 0.15, 0.16), rough=0.4, metal=0.7)
    b.cyl((0.0, -1.0, 1.91), (0, 0, 1), 0.12, 0.02, seg=12, col=(1.0, 0.97, 0.88), em=0.5, rough=0.1)
    b.box((0, 0.97, -0.2 + 0.6), (0.1, 0.06, 0.1), col=(1.0, 0.1, 0.08), em=1.0, rough=0.2)
    b.box((0, -1.02, -0.9), (0.1, 0.06, 0.1), col=(1.0, 0.1, 0.08), em=1.0, rough=0.2)
    for sx, c in ((1, (1.0, 0.1, 0.08)), (-1, (0.1, 1.0, 0.25))):
        b.box((sx * 0.78, 0.6, -4.9), (0.04, 0.05, 0.08), col=c, em=1.0, rough=0.2)
    body = b.obj("heli_body")
    U.select_only(body)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))
    except Exception:
        bpy.ops.object.shade_smooth()
    # main rotor: 4 blades with twist-free aerofoil boxes, hub (centred at origin)
    r = B()
    for k in range(4):
        rot = Matrix.Rotation(k * math.pi / 2, 3, 'Y')
        r.box(tuple(rot @ Vector((0, 0, 2.55))), (0.32, 0.045, 4.7), col=(0.06, 0.06, 0.065), rough=0.45, metal=0.3, rot=rot)
        r.box(tuple(rot @ Vector((0, 0.001, 4.75))), (0.33, 0.047, 0.3), col=(0.92, 0.85, 0.1), rough=0.4, rot=rot)
    r.cyl((0, 0.05, 0), (0, 1, 0), 0.22, 0.16, seg=12, col=(0.2, 0.2, 0.22), rough=0.4, metal=0.8)
    rotor = r.obj("heli_rotor")
    t = B()
    for k in range(2):
        rot = Matrix.Rotation(k * math.pi, 3, 'X')
        t.box(tuple(rot @ Vector((0, 0, 0.42))), (0.03, 0.12, 0.8), col=(0.06, 0.06, 0.065), rough=0.45, rot=rot)
    t.cyl((0, 0, 0), (1, 0, 0), 0.06, 0.1, seg=8, col=(0.2, 0.2, 0.22), rough=0.4, metal=0.8)
    tail = t.obj("heli_tail_rotor")
    return [body, rotor, tail]


def main():
    U.reset()
    materials()
    objs = []
    meta = {}
    only = [a for a in sys.argv[sys.argv.index("--") + 1:] if not a.startswith("-")] if "--" in sys.argv else []
    for kind, spec in CARS.items():
        if only and kind not in only:
            continue
        body, bars, info = build_car(kind, spec)
        objs.append(body)
        objs += bars
        meta[kind] = info
        print(kind, len(body.data.polygons), "faces")
    objs.append(build_wheel())
    if not only or "heli" in only:
        objs += build_heli()
    if "--noexport" not in sys.argv:
        # only the "Col" attribute, as COLOR_0 (exporting all colours adds a fake white COLOR_0)
        U.export_glb(OUT, objs, animations=False, extra=dict(export_vertex_color='NAME', export_vertex_color_name="Col",
                                                              export_all_vertex_colors=False))
        with open(OUT.replace(".glb", ".json"), "w") as f:
            json.dump(meta, f, indent=1)
        print("exported", OUT, os.path.getsize(OUT) // 1024, "KB")
    if "--preview" in sys.argv:
        bpy.ops.wm.save_as_mainfile(filepath="/tmp/cars.blend")


if __name__ == "__main__":
    main()
