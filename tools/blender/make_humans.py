"""Build assets/models/human.glb: rig + male/female bodies + shells + every animation.

    pip install bpy pillow      (Blender as a Python module)
    python tools/blender/make_humans.py [--preview]
"""
import os
import sys
import math
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Vector, Matrix
import bl_util as U
import humans as H
import human_anims as HA
import human_library as HL

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "models", "human.glb")


def build_body(rig, female):
    nm = "body_f" if female else "body_m"
    b = H.build_body(nm, female)
    H.skin_to(b, rig)
    return b


def finish_body(b, rig, segs, female):
    """Add the face, write regions/AO, cap weights at 4 per vertex."""
    feat = H.add_face_features(b, female)
    regions = list(feat["regions"])
    H.skin_to(feat, rig, "head")
    n0 = len(b.data.vertices)
    name = b.name
    body = U.join([feat, b], name)
    H.write_regions(body, segs, [None] * n0 + regions)
    H.limit_weights(body)
    return body


def add_prop_bone(rig, name, parent, pose_action, frame, world_frame):
    """A bone fixed to `parent` that sits exactly at `world_frame` (4x4, armature space)
    when `pose_action` is playing at `frame` - e.g. a pistol grip in the aim pose."""
    rig.animation_data.action = pose_action
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    hand_pose = rig.pose.bones[parent].matrix.copy()
    hand_rest = rig.data.bones[parent].matrix_local.copy()
    rest = hand_rest @ hand_pose.inverted() @ world_frame
    rig.animation_data.action = None
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = rig.data.edit_bones.new(name)
    eb.head = (0, 0, 0)
    eb.tail = (0, 0.1, 0)
    eb.matrix = rest
    eb.length = 0.1
    eb.parent = rig.data.edit_bones[parent]
    eb.use_deform = True
    bpy.ops.object.mode_set(mode='OBJECT')


def frame_from(origin, fwd, up):
    y = Vector(fwd).normalized()
    z = Vector(up)
    z = (z - y * z.dot(y)).normalized()
    x = y.cross(z)
    m = Matrix((x, y, z)).transposed().to_4x4()
    m.translation = Vector(origin)
    return m


def main():
    t0 = time.time()
    U.reset()
    rig = H.build_armature()
    segs = H.bone_segments(rig)
    bm_ = build_body(rig, False)
    bf_ = build_body(rig, True)
    # regions on the plain bodies first (shells copy them / their weights)
    H.write_regions(bm_, segs)
    H.write_regions(bf_, segs)
    shells = H.make_head_shells(bm_, rig)
    shells += H.make_body_shells(bm_, rig, "_m")
    shells += H.make_body_shells(bf_, rig, "_f")
    body_m = finish_body(bm_, rig, segs, False)
    body_f = finish_body(bf_, rig, segs, True)
    print("meshes", round(time.time() - t0, 1), "s:", body_m.name, len(body_m.data.vertices), body_f.name, len(body_f.data.vertices),
          [s.name for s in shells])

    HA.setup_ik(rig)
    A = HA.Animator(rig)
    clips = HL.build_all(A)
    print("clips", len(clips), round(time.time() - t0, 1), "s")

    # constraints/helpers only existed for authoring
    for pb in rig.pose.bones:
        for c in list(pb.constraints):
            pb.constraints.remove(c)
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='EDIT')
    for b in list(rig.data.edit_bones):
        if not b.use_deform:
            rig.data.edit_bones.remove(b)
    bpy.ops.object.mode_set(mode='OBJECT')

    # prop sockets: pistol grip (aim pose) and phone (phone pose), both in the right hand
    aim = bpy.data.actions["aim_idle"]
    rig.animation_data.action = aim
    bpy.context.scene.frame_set(0)
    bpy.context.view_layer.update()
    hm = rig.pose.bones["hand.R"].matrix
    palm = hm.translation + hm.col[1].xyz * 0.055 + hm.col[0].xyz * 0.0
    add_prop_bone(rig, "weapon.R", "hand.R", aim, 0, frame_from(palm + Vector((0, 0, 0.02)), (0.02, -1, 0.02), (0, 0, 1)))
    ph = bpy.data.actions["phone"]
    rig.animation_data.action = ph
    bpy.context.scene.frame_set(20)
    bpy.context.view_layer.update()
    hm = rig.pose.bones["hand.R"].matrix
    palm = hm.translation + hm.col[1].xyz * 0.05
    head = rig.pose.bones["head"].matrix
    add_prop_bone(rig, "prop.R", "hand.R", ph, 20, frame_from(palm, (0, 0.15, 1), (-1.0, -0.1, 0)))
    rig.animation_data.action = None

    mat = U.material("Human", vcol=True)
    meshes = [body_m, body_f] + shells
    for m in meshes:
        U.set_material(m, mat)
        m.parent = rig
    # A-pose bind is the rest pose; leave the rig in rest for export
    for pb in rig.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.rotation_euler = (0, 0, 0)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    U.export_glb(OUT, [rig] + meshes)
    print("exported", OUT, os.path.getsize(OUT) // 1024, "KB in", round(time.time() - t0, 1), "s")
    if "--preview" in sys.argv:
        bpy.ops.wm.save_as_mainfile(filepath="/tmp/human_build.blend")


if __name__ == "__main__":
    main()
