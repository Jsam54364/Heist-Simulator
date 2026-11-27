"""Low-poly human characters for Heist Simulator: one shared skeleton, male + female
bodies, clothing/hair/hat shells, all skinned. Animations live in human_anims.py.

Body meshes are grown with Blender's Skin modifier from a joint graph (the classic
quick base-mesh technique), smoothed with one Subdivision level, then skinned with
automatic (bone heat) weights. Clothing is NOT separate geometry for most outfits:
every vertex carries a body REGION id and a position T along its limb in UV2, and the
in-game shader decides per character what is skin, sleeve, trouser, shoe... so one mesh
gives endless outfit combinations (short/long sleeves, shorts/trousers, tank tops) with a
single draw call. Shells (vests, duty belts, jackets, hair, hats, masks) are offset copies
of the body surface, so they fit perfectly and deform with the same weights.
"""
import math
import random
import bpy
import bmesh
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree
import bl_util as U

# ------------------------------------------------------------------ regions
HEAD, HAND, FOREARM, UPPER_ARM, TORSO, BELLY, PELVIS, THIGH, SHIN, FOOT, EYE, HAIR, LIP, GEAR, HAT, NECK = range(16)
CHAIN_OFF = {UPPER_ARM: 0.0, FOREARM: 1.0, HAND: 2.0, THIGH: 0.0, SHIN: 1.0, FOOT: 2.0}
BROW = HAIR
PREVIEW = {HEAD: (0.86, 0.64, 0.5), HAND: (0.86, 0.64, 0.5), FOREARM: (0.86, 0.64, 0.5), UPPER_ARM: (0.2, 0.45, 0.85),
           TORSO: (0.2, 0.45, 0.85), BELLY: (0.2, 0.45, 0.85), PELVIS: (0.25, 0.27, 0.3), THIGH: (0.25, 0.27, 0.3),
           SHIN: (0.25, 0.27, 0.3), FOOT: (0.1, 0.1, 0.1), EYE: (0.05, 0.04, 0.03), BROW: (0.2, 0.13, 0.08),
           LIP: (0.7, 0.4, 0.38), GEAR: (0.12, 0.13, 0.14), HAT: (0.7, 0.2, 0.2), NECK: (0.86, 0.64, 0.5)}

FRONT = Vector((0, -1, 0))
BACK = Vector((0, 1, 0))
UP = Vector((0, 0, 1))

# ------------------------------------------------------------------ skeleton
# name: (head, tail, parent, roll_z_axis, deform)
# Bone local axes are set so that +X rotation is natural flexion for every joint
# (spine bends forward, knees bend, elbows bend) - poses are written that way.
BONES_L = [
    ("hips", (0, 0.0, 0.96), (0, 0.0, 1.06), None, FRONT),
    ("spine", (0, 0.0, 1.06), (0, -0.005, 1.20), "hips", FRONT),
    ("chest", (0, -0.005, 1.20), (0, 0.0, 1.44), "spine", FRONT),
    ("neck", (0, 0.0, 1.44), (0, -0.018, 1.545), "chest", FRONT),
    ("head", (0, -0.018, 1.545), (0, -0.018, 1.77), "neck", FRONT),
    ("shoulder.L", (0.025, -0.01, 1.40), (0.165, 0.0, 1.405), "chest", FRONT),
    ("upper_arm.L", (0.17, 0.0, 1.40), (0.392, 0.012, 1.215), "shoulder.L", FRONT),
    ("forearm.L", (0.392, 0.012, 1.215), (0.585, -0.02, 1.04), "upper_arm.L", FRONT),
    ("hand.L", (0.585, -0.02, 1.04), (0.638, -0.026, 0.99), "forearm.L", FRONT),
    ("fingers.L", (0.638, -0.026, 0.99), (0.69, -0.03, 0.94), "hand.L", FRONT),
    ("thumb.L", (0.598, -0.045, 1.03), (0.622, -0.075, 1.005), "hand.L", FRONT),
    ("thigh.L", (0.095, 0.0, 0.94), (0.10, -0.005, 0.52), "hips", FRONT),
    ("shin.L", (0.10, -0.005, 0.52), (0.10, 0.018, 0.095), "thigh.L", BACK),
    ("foot.L", (0.10, 0.018, 0.095), (0.10, -0.095, 0.035), "shin.L", UP),
    ("toe.L", (0.10, -0.095, 0.035), (0.10, -0.165, 0.025), "foot.L", UP),
]
# animation helpers (not exported): IK targets and poles, in armature space
HELPERS = [
    ("foot_ik.L", (0.10, 0.018, 0.095), (0.10, -0.08, 0.095)),
    ("knee_pole.L", (0.10, -0.55, 0.52), (0.10, -0.6, 0.52)),
    ("hand_ik.L", (0.585, -0.02, 1.04), (0.638, -0.026, 0.99)),
    ("elbow_pole.L", (0.45, 0.45, 1.215), (0.45, 0.5, 1.215)),
]


def mirror_name(n):
    return n[:-2] + ".R" if n.endswith(".L") else (n[:-2] + ".L" if n.endswith(".R") else n)


def mx(v):
    return (-v[0], v[1], v[2])


def all_bones():
    out = []
    for b in BONES_L:
        out.append(b)
        if b[0].endswith(".L"):
            out.append((mirror_name(b[0]), mx(b[1]), mx(b[2]), mirror_name(b[3]) if b[3] and b[3].endswith(".L") else b[3], b[4]))
    return out


def all_helpers():
    out = []
    for h in HELPERS:
        out.append(h)
        out.append((mirror_name(h[0]), mx(h[1]), mx(h[2])))
    return out


def build_armature():
    arm = bpy.data.armatures.new("HumanRig")
    obj = bpy.data.objects.new("HumanRig", arm)
    U.link(obj)
    U.select_only(obj)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.edit_bones
    for name, h, t, parent, zaxis in all_bones():
        b = eb.new(name)
        b.head = h
        b.tail = t
        b.align_roll(zaxis)
        b.use_deform = True
        if parent:
            b.parent = eb[parent]
            b.use_connect = (Vector(eb[parent].tail) - Vector(h)).length < 1e-4
    for name, h, t in all_helpers():
        b = eb.new(name)
        b.head = h
        b.tail = t
        b.use_deform = False
    bpy.ops.object.mode_set(mode='OBJECT')
    return obj


def bone_segments(rig):
    segs = {}
    for b in rig.data.bones:
        if b.use_deform:
            segs[b.name] = (Vector(b.head_local), Vector(b.tail_local))
    return segs


# ------------------------------------------------------------------ body
def skin_graph(female=False):
    """(name, pos, (rx, ry)) joints and edges for the Skin modifier."""
    f = female
    J = {
        "pelvis": ((0, 0.010, 0.95), (0.168 if f else 0.158, 0.112 if f else 0.108)),
        "waist": ((0, 0.006, 1.06), (0.128 if f else 0.146, 0.094 if f else 0.102)),
        "belly": ((0, 0.0, 1.16), (0.130 if f else 0.152, 0.098 if f else 0.108)),
        "chest": ((0, -0.016 if f else 0.0, 1.285), (0.150 if f else 0.178, 0.128 if f else 0.120)),
        "uchest": ((0, 0.004, 1.385), (0.146 if f else 0.172, 0.100 if f else 0.106)),
        "trap": ((0, 0.010, 1.44), (0.100 if f else 0.120, 0.070 if f else 0.078)),
        "neck0": ((0, 0.006, 1.475), (0.056 if f else 0.066, 0.056 if f else 0.064)),
        "neck1": ((0, -0.004, 1.53), (0.050 if f else 0.058, 0.052 if f else 0.060)),
        "jaw": ((0, -0.022, 1.575), (0.066 if f else 0.076, 0.076 if f else 0.086)),
        "head1": ((0, -0.022, 1.648), (0.090 if f else 0.094, 0.104 if f else 0.108)),
        "head2": ((0, -0.012, 1.716), (0.086 if f else 0.090, 0.100 if f else 0.103)),
        "head3": ((0, -0.002, 1.762), (0.050 if f else 0.052, 0.060 if f else 0.062)),
        "sh.L": ((0.168, 0.0, 1.398), (0.058 if f else 0.068, 0.058 if f else 0.068)),
        "bicep.L": ((0.28, 0.006, 1.305), (0.046 if f else 0.055, 0.048 if f else 0.057)),
        "elb.L": ((0.392, 0.012, 1.215), (0.038 if f else 0.044, 0.040 if f else 0.046)),
        "fore.L": ((0.48, 0.0, 1.14), (0.040 if f else 0.047, 0.034 if f else 0.040)),
        "wri.L": ((0.585, -0.02, 1.04), (0.028 if f else 0.032, 0.022 if f else 0.025)),
        "palm.L": ((0.632, -0.025, 0.995), (0.042 if f else 0.047, 0.017 if f else 0.019)),
        "fing.L": ((0.688, -0.03, 0.942), (0.034 if f else 0.038, 0.014 if f else 0.015)),
        "thumb.L": ((0.618, -0.068, 1.012), (0.013, 0.013)),
        "hip.L": ((0.096, 0.0, 0.90), (0.096 if f else 0.090, 0.098 if f else 0.094)),
        "thighm.L": ((0.099, -0.006, 0.72), (0.080 if f else 0.078, 0.082 if f else 0.082)),
        "knee.L": ((0.10, -0.006, 0.52), (0.056 if f else 0.058, 0.060 if f else 0.062)),
        "calf.L": ((0.10, 0.016, 0.37), (0.053 if f else 0.057, 0.058 if f else 0.063)),
        "ank.L": ((0.10, 0.02, 0.105), (0.034 if f else 0.038, 0.038 if f else 0.042)),
        "ball.L": ((0.10, -0.07, 0.045), (0.044 if f else 0.048, 0.042 if f else 0.046)),
        "toe.L": ((0.10, -0.148, 0.034), (0.038 if f else 0.042, 0.028 if f else 0.030)),
    }
    E = [("pelvis", "waist"), ("waist", "belly"), ("belly", "chest"), ("chest", "uchest"), ("uchest", "trap"), ("trap", "neck0"),
         ("neck0", "neck1"), ("neck1", "jaw"), ("jaw", "head1"), ("head1", "head2"), ("head2", "head3")]
    for s in ["L", "R"]:
        E += [("uchest", f"sh.{s}"), (f"sh.{s}", f"bicep.{s}"), (f"bicep.{s}", f"elb.{s}"), (f"elb.{s}", f"fore.{s}"),
              (f"fore.{s}", f"wri.{s}"), (f"wri.{s}", f"palm.{s}"), (f"palm.{s}", f"fing.{s}"), (f"wri.{s}", f"thumb.{s}"),
              ("pelvis", f"hip.{s}"), (f"hip.{s}", f"thighm.{s}"), (f"thighm.{s}", f"knee.{s}"), (f"knee.{s}", f"calf.{s}"),
              (f"calf.{s}", f"ank.{s}"), (f"ank.{s}", f"ball.{s}"), (f"ball.{s}", f"toe.{s}")]
    full = {}
    for k, v in J.items():
        full[k] = v
        if k.endswith(".L"):
            full[k[:-2] + ".R"] = (mx(v[0]), v[1])
    return full, E


def build_body(name, female=False):
    J, E = skin_graph(female)
    names = list(J.keys())
    me = bpy.data.meshes.new(name)
    me.from_pydata([J[n][0] for n in names], [(names.index(a), names.index(b)) for a, b in E], [])
    obj = bpy.data.objects.new(name, me)
    U.link(obj)
    sk = obj.modifiers.new("Skin", 'SKIN')
    sk.branch_smoothing = 0.6
    sk.use_smooth_shade = True
    for i, n in enumerate(names):
        r = J[n][1]
        obj.data.skin_vertices[0].data[i].radius = r
        obj.data.skin_vertices[0].data[i].use_root = (n == "pelvis")
    sub = obj.modifiers.new("Sub", 'SUBSURF')
    sub.levels = 1
    sub.render_levels = 1
    U.apply_modifiers(obj)
    sculpt(obj, body_bumps(female))
    U.shade_smooth(obj)
    return obj


def body_bumps(female):
    """Anatomy the tube-like skin hull lacks: (centre, radii, push along normal)."""
    b = []
    for s in (1, -1):
        b += [
            ((0.19 * s, -0.005, 1.37), (0.07, 0.07, 0.08), 0.014),       # deltoid
            ((0.07 * s, -0.11, 1.30), (0.075, 0.06, 0.06), 0.022 if female else 0.012),  # pec / bust
            ((0.07 * s, 0.10, 0.88), (0.08, 0.07, 0.08), 0.022 if female else 0.016),   # glute
            ((0.10 * s, 0.07, 0.40), (0.05, 0.05, 0.08), 0.012),         # calf
            ((0.10 * s, -0.07, 0.74), (0.06, 0.05, 0.12), 0.008),        # quad
            ((0.075 * s, 0.09, 1.30), (0.07, 0.05, 0.09), 0.008),        # shoulder blade
            ((0.24 * s, -0.02, 1.32), (0.035, 0.04, 0.06), 0.006),       # bicep
            ((0.04 * s, -0.10, 1.60), (0.035, 0.03, 0.03), 0.006),       # cheek
        ]
    b.append(((0, -0.115, 1.565), (0.03, 0.03, 0.025), 0.008))           # chin
    b.append(((0, -0.10, 1.69), (0.06, 0.03, 0.025), 0.006))             # brow ridge
    if not female:
        b.append(((0, -0.10, 1.12), (0.09, 0.05, 0.06), 0.006))           # belly
    return b


def sculpt(obj, bumps):
    me = obj.data
    me.update()
    for v in me.vertices:
        n = v.normal
        push = 0.0
        for c, r, amt in bumps:
            d = Vector(((v.co.x - c[0]) / r[0], (v.co.y - c[1]) / r[1], (v.co.z - c[2]) / r[2]))
            q = d.length_squared
            if q < 4.0:
                push += amt * math.exp(-q * 1.5)
        v.co += n * push


def surface_point(bvh, x, z, from_y=-0.6, dir=(0, 1, 0)):
    hit = bvh.ray_cast(Vector((x, from_y, z)), Vector(dir))
    return hit[0]


def add_face_features(body, female=False):
    """Eyes, brows, nose, mouth, ears: small pieces stuck onto the head surface."""
    bvh = BVHTree.FromObject(body, bpy.context.evaluated_depsgraph_get())
    bm = bmesh.new()
    regions = []

    def add(geom_verts, region):
        regions.extend([region] * len(geom_verts))

    def ellipsoid(center, size, region, segs=8, rings=5):
        res = bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0)
        vs = res["verts"]
        for v in vs:
            v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2])) + Vector(center)
        add(vs, region)

    def box(center, size, region, rot_y=0.0):
        res = bmesh.ops.create_cube(bm, size=1.0)
        vs = res["verts"]
        m = Matrix.Rotation(rot_y, 3, 'Y')
        for v in vs:
            v.co = m @ Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2])) + Vector(center)
        add(vs, region)

    for s in [1, -1]:
        ex = 0.034 * s
        ez = 1.664
        p = surface_point(bvh, ex, ez)
        if p is None:
            continue
        ellipsoid(p + Vector((0, 0.003, 0)), (0.012, 0.005, 0.014), EYE, 8, 5)
        pb = surface_point(bvh, ex * 1.05, ez + 0.026)
        if pb is not None:
            box(pb + Vector((0, 0.0005, 0)), (0.032 if not female else 0.028, 0.006, 0.0055 if not female else 0.004), BROW, -0.14 * s)
        # ear
        pe = surface_point(bvh, 0.0, 1.648, from_y=-0.02, dir=(0, 0, 1))
        ear_x = 0.0
        hit = bvh.ray_cast(Vector((0.4 * s, -0.012, 1.648)), Vector((-s, 0, 0)))
        if hit[0] is not None:
            ear_x = hit[0].x
            ellipsoid(Vector((ear_x + 0.006 * s, -0.008, 1.645)), (0.011, 0.024, 0.032), HEAD, 6, 4)
    pn = surface_point(bvh, 0.0, 1.632)
    if pn is not None:
        ellipsoid(pn + Vector((0, -0.004, 0.006)), (0.012 if not female else 0.010, 0.016, 0.022), HEAD, 8, 6)
        ellipsoid(pn + Vector((0, -0.008, -0.008)), (0.016 if not female else 0.013, 0.012, 0.009), HEAD, 8, 5)
    pm = surface_point(bvh, 0.0, 1.598)
    if pm is not None:
        box(pm + Vector((0, 0.003, 0)), (0.038 if not female else 0.034, 0.012, 0.007 if not female else 0.009), LIP)
    me = bpy.data.meshes.new("features")
    bm.to_mesh(me)
    bm.free()
    feat = bpy.data.objects.new("features", me)
    U.link(feat)
    U.shade_smooth(feat)
    feat["regions"] = regions
    return feat


# region classification ------------------------------------------------------
BONE_REGION = {
    "head": HEAD, "neck": NECK, "chest": TORSO, "spine": BELLY, "hips": PELVIS,
    "shoulder": TORSO, "upper_arm": UPPER_ARM, "forearm": FOREARM, "hand": HAND, "fingers": HAND, "thumb": HAND,
    "thigh": THIGH, "shin": SHIN, "foot": FOOT, "toe": FOOT,
}


def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return (p - (a + ab * t)).length, (p - a).dot(ab) / ab.length_squared


def classify(co, segs):
    best = None
    bd = 1e9
    bt = 0.0
    for name, (a, b) in segs.items():
        d, t = seg_dist(co, a, b)
        base = name.split(".")[0]
        # bias: torso bones are fat, so compare against their radius
        if base in ("chest", "spine", "hips"):
            d -= 0.08
        elif base in ("thigh",):
            d -= 0.03
        if d < bd:
            bd, best, bt = d, base, t
    r = BONE_REGION[best]
    t = bt
    # shoulders blend into the torso / top of the upper arm
    if best == "neck" and co.z > 1.5:
        r = HEAD
    if best == "chest" and co.z > 1.455 and abs(co.x) < 0.09:
        r = NECK
    if best in ("chest",) and co.z < 1.19:
        r = BELLY
    if best == "hips" and co.z > 1.03:
        r = BELLY
    return r, max(0.0, min(1.0, t))


def write_regions(obj, segs, forced=None):
    """UV2 'Region' = (t along limb, region id); Col = preview colour + AO in alpha."""
    me = obj.data
    uv = U.uv_layer(obj, "Region")
    col = U.ensure_color(obj, "Col")
    per_vert = []
    for i, v in enumerate(me.vertices):
        if forced is not None and forced[i] is not None:
            per_vert.append((forced[i], 0.5))
        else:
            per_vert.append(classify(v.co, segs))
    ao = vertex_ao(obj)
    for poly in me.polygons:
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            r, t = per_vert[vi]
            # U = position along the limb CHAIN (upper arm 0-1, forearm 1-2, hand 2-3; thigh,
            # shin, foot likewise) so it interpolates smoothly across joints - no seams where
            # a triangle mixes two regions. Non-limb regions sit at 0 (the chain root).
            u = t + CHAIN_OFF[r] if r in CHAIN_OFF else 0.0
            uv.data[li].uv = (u, (r + 0.5) / 16.0)
            c = PREVIEW[r]
            a = ao[vi]
            col.data[li].color = (c[0] * a, c[1] * a, c[2] * a, a)


def vertex_ao(obj, rays=20, dist=0.18):
    """Cheap ambient occlusion: hemisphere ray casts against the mesh itself."""
    dg = bpy.context.evaluated_depsgraph_get()
    bvh = BVHTree.FromObject(obj, dg)
    me = obj.data
    me.calc_loop_triangles()
    rnd = random.Random(7)
    dirs = []
    for k in range(rays):
        u = rnd.random()
        v = rnd.random()
        th = 2 * math.pi * u
        z = v
        rr = math.sqrt(1 - z * z)
        dirs.append(Vector((rr * math.cos(th), rr * math.sin(th), z)))
    out = []
    for v in me.vertices:
        n = v.normal.normalized()
        q = n.to_track_quat('Z', 'Y')
        occ = 0
        for d in dirs:
            w = q @ d
            hit = bvh.ray_cast(v.co + n * 0.003, w, dist)
            if hit[0] is not None:
                occ += 1
        out.append(max(0.35, 1.0 - occ / rays * 0.85))
    return out


def skin_to(obj, rig, forced_bone=None):
    """Parent with automatic (bone heat) weights, or rigidly to one bone."""
    if forced_bone:
        obj.parent = rig
        mod = obj.modifiers.new("Armature", 'ARMATURE')
        mod.object = rig
        vg = obj.vertex_groups.new(name=forced_bone)
        vg.add(list(range(len(obj.data.vertices))), 1.0, 'REPLACE')
        return
    U.select_only(obj, rig)
    bpy.ops.object.parent_set(type='ARMATURE_AUTO')


def limit_weights(obj, n=4):
    me = obj.data
    for v in me.vertices:
        gs = sorted(v.groups, key=lambda g: -g.weight)
        keep = gs[:n]
        tot = sum(g.weight for g in keep) or 1.0
        for g in v.groups:
            if g not in keep:
                g.weight = 0.0
        for g in keep:
            g.weight /= tot


def copy_weights(src, dst):
    """Give dst (a shell around src) the weights of the nearest src vertex."""
    from mathutils.kdtree import KDTree
    kd = KDTree(len(src.data.vertices))
    for i, v in enumerate(src.data.vertices):
        kd.insert(v.co, i)
    kd.balance()
    names = {g.index: g.name for g in src.vertex_groups}
    for g in src.vertex_groups:
        if g.name not in dst.vertex_groups:
            dst.vertex_groups.new(name=g.name)
    for v in dst.data.vertices:
        _, i, _ = kd.find(v.co)
        for g in src.data.vertices[i].groups:
            dst.vertex_groups[names[g.group]].add([v.index], g.weight, 'REPLACE')
    dst.parent = src.parent
    mod = dst.modifiers.new("Armature", 'ARMATURE')
    mod.object = src.parent


def shell(body, name, keep_fn, offset, thicken=0.0, region=TORSO):
    """Copy the faces of `body` that pass keep_fn(face_center, face_normal, region) and push them out."""
    me = body.data.copy()
    me.name = name
    obj = bpy.data.objects.new(name, me)
    U.link(obj)
    bm = bmesh.new()
    bm.from_mesh(me)
    uvl = bm.loops.layers.uv.get("Region")
    dead = []
    for f in bm.faces:
        rid = int(f.loops[0][uvl].uv.y * 16.0) if uvl else -1
        if not keep_fn(f.calc_center_median(), f.normal, rid):
            dead.append(f)
    bmesh.ops.delete(bm, geom=dead, context='FACES')
    bm.normal_update()
    for v in bm.verts:
        v.co += v.normal * offset
    if thicken > 0.0:
        ret = bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=thicken)
    bm.to_mesh(me)
    bm.free()
    obj.data = me
    # shells carry a single region id (its colour comes from the character's palette)
    uv = U.uv_layer(obj, "Region")
    for l in me.loops:
        uv.data[l.index].uv = (0.5, (region + 0.5) / 16.0)
    obj.vertex_groups.clear()
    return obj


# ------------------------------------------------------------------ head / body shells
HEAD_C = Vector((0, -0.02, 1.662))


def _hair_keep(th_front, th_side, th_back, zmin=1.45):
    def fn(c, n, rid):
        if rid not in (HEAD, NECK) or c.z < zmin:
            return False
        d = (c - HEAD_C).normalized()
        f = -d.y
        thr = th_side + (th_front - th_side) * max(0.0, f) + (th_back - th_side) * max(0.0, -f)
        return d.z > thr
    return fn


def _bump(obj, center, radius, amount):
    for v in obj.data.vertices:
        d = (v.co - Vector(center)).length
        if d < radius * 2:
            v.co += v.normal * amount * math.exp(-(d / radius) ** 2 * 1.5)


def make_head_shells(body, rig):
    """Hair styles, hats, mask - fitted to the head, rigid on the head bone."""
    out = []

    def finish(o, region, thick=0.0):
        if thick:
            bm = bmesh.new()
            bm.from_mesh(o.data)
            bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=thick)
            bm.to_mesh(o.data)
            bm.free()
        uv = U.uv_layer(o, "Region")
        for l in o.data.loops:
            uv.data[l.index].uv = (0.5, (region + 0.5) / 16.0)
        U.shade_smooth(o)
        U.solid_color(o, tuple(PREVIEW[region]) + (1.0,))
        o.vertex_groups.clear()
        skin_to(o, rig, "head")
        out.append(o)
        return o

    finish(shell(body, "hair_short", _hair_keep(0.52, 0.14, -0.30), 0.012), HAIR, 0.012)
    finish(shell(body, "hair_buzz", _hair_keep(0.45, 0.16, -0.25), 0.004), HAIR)
    finish(shell(body, "hair_afro", _hair_keep(0.36, 0.0, -0.40), 0.045), HAIR, 0.03)
    # long hair: cap + a drape off the back down to the shoulders
    lh = shell(body, "hair_long", _hair_keep(0.40, -0.25, -0.55), 0.014)
    bm = bmesh.new()
    bm.from_mesh(lh.data)
    edges = [e for e in bm.edges if e.is_boundary and all(v.co.y > -0.02 for v in e.verts)]
    ret = bmesh.ops.extrude_edge_only(bm, edges=edges)
    nv = [g for g in ret["geom"] if isinstance(g, bmesh.types.BMVert)]
    for v in nv:
        v.co.z -= 0.17
        v.co.y += 0.03
        v.co.x *= 1.08
    bm.to_mesh(lh.data)
    bm.free()
    finish(lh, HAIR, 0.012)
    # ponytail / bun: short cap + a lump
    for nm, centre, size in (("hair_ponytail", (0, 0.125, 1.63), (0.032, 0.045, 0.10)), ("hair_bun", (0, 0.085, 1.765), (0.05, 0.05, 0.045))):
        cap = shell(body, nm, _hair_keep(0.40, 0.05, -0.35), 0.012)
        bm = bmesh.new()
        bm.from_mesh(cap.data)
        res = bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=1.0)
        for v in res["verts"]:
            v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2])) + Vector(centre)
        bm.to_mesh(cap.data)
        bm.free()
        finish(cap, HAIR, 0.01)
    # hats
    cap = shell(body, "cap", _hair_keep(0.55, 0.22, 0.10), 0.022)
    bm = bmesh.new()
    bm.from_mesh(cap.data)
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Matrix.Rotation(math.radians(10), 3, 'X') @ Vector((v.co.x * 0.17, v.co.y * 0.095, v.co.z * 0.008)) + Vector((0, -0.17, 1.715))
    bm.to_mesh(cap.data)
    bm.free()
    finish(cap, HAT, 0.008)
    beanie = shell(body, "beanie", _hair_keep(0.48, 0.16, -0.05), 0.02)
    finish(beanie, HAT, 0.01)
    helm = shell(body, "helmet", _hair_keep(0.50, 0.02, -0.25), 0.038)
    finish(helm, GEAR, 0.012)
    # police peaked cap: crown cylinder + flat top + visor
    bm = bmesh.new()
    res = bmesh.ops.create_cone(bm, cap_ends=True, segments=14, radius1=0.104, radius2=0.118, depth=0.075)
    for v in res["verts"]:
        v.co = Vector((v.co.x, v.co.y * 1.12, v.co.z)) + Vector((0, -0.012, 1.755))
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Matrix.Rotation(math.radians(18), 3, 'X') @ Vector((v.co.x * 0.15, v.co.y * 0.07, v.co.z * 0.008)) + Vector((0, -0.14, 1.725))
    ph = U.mesh_from_bmesh("police_hat", bm)
    finish(ph, HAT)
    # balaclava: whole head + neck with an eye slit, bumped over nose/ears
    def mask_keep(c, n, rid):
        if rid not in (HEAD, NECK) or c.z < 1.46:
            return False
        if c.y < -0.06 and 1.643 < c.z < 1.69 and abs(c.x) < 0.075:
            return False
        return True
    mk = shell(body, "mask", mask_keep, 0.008)
    _bump(mk, (0, -0.125, 1.628), 0.022, 0.026)
    for s in (1, -1):
        _bump(mk, (0.095 * s, -0.01, 1.645), 0.025, 0.018)
    _bump(mk, (0, -0.12, 1.598), 0.02, 0.008)
    finish(mk, GEAR, 0.004)
    # sunglasses
    bm = bmesh.new()
    for s in (1, -1):
        res = bmesh.ops.create_cube(bm, size=1.0)
        for v in res["verts"]:
            v.co = Vector((v.co.x * 0.036, v.co.y * 0.008, v.co.z * 0.022)) + Vector((0.034 * s, -0.128, 1.666))
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Vector((v.co.x * 0.03, v.co.y * 0.006, v.co.z * 0.006)) + Vector((0, -0.13, 1.672))
    for s in (1, -1):
        res = bmesh.ops.create_cube(bm, size=1.0)
        for v in res["verts"]:
            v.co = Vector((v.co.x * 0.004, v.co.y * 0.10, v.co.z * 0.006)) + Vector((0.085 * s, -0.08, 1.672))
    gl = U.mesh_from_bmesh("sunglasses", bm)
    finish(gl, EYE)
    return out


def make_body_shells(body, rig, sfx):
    out = []

    def finish(o, region, thick):
        if thick:
            bm = bmesh.new()
            bm.from_mesh(o.data)
            bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=thick)
            bm.to_mesh(o.data)
            bm.free()
        uv = U.uv_layer(o, "Region")
        for l in o.data.loops:
            uv.data[l.index].uv = (0.5, (region + 0.5) / 16.0)
        U.shade_smooth(o)
        U.solid_color(o, tuple(PREVIEW[region]) + (1.0,))
        copy_weights(body, o)
        limit_weights(o)
        out.append(o)
        return o

    vest = shell(body, "vest" + sfx, lambda c, n, r: r in (TORSO, BELLY) and 1.03 < c.z < 1.43 and abs(c.x) < 0.175, 0.03)
    finish(vest, GEAR, 0.012)
    belt = shell(body, "duty_belt" + sfx, lambda c, n, r: r in (PELVIS, BELLY) and 0.955 < c.z < 1.03, 0.018)
    # holster on the right hip
    bm = bmesh.new()
    bm.from_mesh(belt.data)
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res["verts"]:
        v.co = Vector((v.co.x * 0.05, v.co.y * 0.075, v.co.z * 0.15)) + Vector((-0.185, 0.0, 0.93))
    bm.to_mesh(belt.data)
    bm.free()
    finish(belt, GEAR, 0.008)
    jk = shell(body, "jacket" + sfx, lambda c, n, r: (r in (TORSO, BELLY, NECK) and c.z < 1.49) or r == UPPER_ARM or
               (r == FOREARM and c.z > 1.06) or (r == PELVIS and c.z > 0.93), 0.013)
    finish(jk, TORSO, 0.006)
    return out
