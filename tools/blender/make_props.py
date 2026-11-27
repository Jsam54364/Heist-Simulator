"""Hand props: pistol, phone, duffel bag -> assets/models/props.glb (one node each).

Each prop's origin is its attachment point: the pistol at the grip (barrel along -Y in
Blender = +Z in Godot, matching the rig's weapon.R socket), the phone at its centre, the
bag at its carry strap.
"""
import os
import sys
import math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import bmesh
from mathutils import Vector, Matrix
import bl_util as U

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "models", "props.glb")


def box(bm, center, size, rot=None, bevel=0.0):
    res = bmesh.ops.create_cube(bm, size=1.0)
    vs = res["verts"]
    for v in vs:
        p = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
        if rot is not None:
            p = rot @ p
        v.co = p + Vector(center)
    return vs


def cyl(bm, center, r, depth, axis='Y', segs=10):
    res = bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r, depth=depth)
    rot = {'X': Matrix.Rotation(math.pi / 2, 3, 'Y'), 'Y': Matrix.Rotation(math.pi / 2, 3, 'X'), 'Z': Matrix.Identity(3)}[axis]
    for v in res["verts"]:
        v.co = rot @ v.co + Vector(center)
    return res["verts"]


def colored(name, parts):
    """parts: [(builder(bm) -> verts, rgba)] -> one object, colours per vertex."""
    bm = bmesh.new()
    cols = []
    for fn, c in parts:
        vs = fn(bm)
        cols.append((list(vs), c))
    bm.verts.index_update()
    lookup = {}
    for vs, c in cols:
        for v in vs:
            lookup[v.index] = c
    obj = U.mesh_from_bmesh(name, bm)
    U.paint_corners(obj, lambda p, vi, co: lookup.get(vi, (0.5, 0.5, 0.5, 1)))
    return obj


def bevel(obj, w=0.003, segs=1):
    m = obj.modifiers.new("Bevel", 'BEVEL')
    m.width = w
    m.segments = segs
    m.limit_method = 'ANGLE'
    U.apply_modifiers(obj)


def pistol():
    black = (0.07, 0.075, 0.08, 1)
    dark = (0.16, 0.17, 0.18, 1)
    tilt = Matrix.Rotation(math.radians(-14), 3, 'X')
    o = colored("pistol", [
        (lambda bm: box(bm, (0, -0.075, 0.055), (0.026, 0.19, 0.032)), dark),              # slide
        (lambda bm: box(bm, (0, -0.07, 0.03), (0.024, 0.17, 0.022)), black),               # frame
        (lambda bm: box(bm, (0, 0.0, -0.025), (0.026, 0.045, 0.11), tilt), black),         # grip
        (lambda bm: box(bm, (0, -0.045, 0.005), (0.008, 0.03, 0.012)), black),             # trigger guard
        (lambda bm: cyl(bm, (0, -0.172, 0.055), 0.0055, 0.006, 'Y', 8), (0.02, 0.02, 0.02, 1)),  # muzzle
        (lambda bm: box(bm, (0, -0.16, 0.074), (0.004, 0.008, 0.006)), black),              # front sight
        (lambda bm: box(bm, (0, 0.012, 0.074), (0.016, 0.008, 0.006)), black),              # rear sight
    ])
    bevel(o, 0.002)
    U.shade_smooth(o, 40)
    return o


def phone():
    o = colored("phone", [
        (lambda bm: box(bm, (0, 0, 0), (0.072, 0.008, 0.148)), (0.06, 0.06, 0.07, 1)),
        (lambda bm: box(bm, (0, -0.0045, 0.0), (0.064, 0.001, 0.136)), (0.15, 0.32, 0.55, 1)),
    ])
    bevel(o, 0.003)
    U.shade_smooth(o, 40)
    return o


def duffel():
    body = (0.11, 0.12, 0.13, 1)
    strap = (0.05, 0.05, 0.05, 1)
    zip_ = (0.55, 0.5, 0.35, 1)

    def bag(bm):
        vs = cyl(bm, (0, 0, -0.13), 0.13, 0.52, 'X', 14)
        for v in vs:
            v.co.z = -0.13 + (v.co.z + 0.13) * 0.85
        return vs
    o = colored("duffel", [
        (bag, body),
        (lambda bm: box(bm, (0, -0.0, -0.02), (0.30, 0.012, 0.03)), zip_),
        (lambda bm: box(bm, (0.12, 0.0, -0.02), (0.03, 0.02, 0.06)), strap),
        (lambda bm: box(bm, (-0.12, 0.0, -0.02), (0.03, 0.02, 0.06)), strap),
    ])
    sub = o.modifiers.new("s", 'SUBSURF')
    sub.levels = 1
    U.apply_modifiers(o)
    U.shade_smooth(o)
    return o


def main():
    U.reset()
    objs = [pistol(), phone(), duffel()]
    mat = U.material("Prop", vcol=True, rough=0.5)
    for o in objs:
        U.set_material(o, mat)
    U.export_glb(OUT, objs, animations=False)
    print("exported", OUT)


if __name__ == "__main__":
    main()
