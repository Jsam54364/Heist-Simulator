"""Clips driven by motion capture (CMU, see mocap.py). Built after the keyed library and
replacing clips of the same name; the keyed versions remain as fallbacks for anything not
listed here. Aim locomotion = mocap legs/pelvis + the keyed aiming torso and arms, with the
spine counter-rotating against the pelvis swing so the gun stays on target."""
import math
import bpy
import numpy as np
import human_anims as HA
import human_library as HL
import mocap as MC

INFO = {}


def _drop(A, name):
    a = bpy.data.actions.get(name)
    if a:
        if a in A.actions:
            A.actions.remove(a)
        bpy.data.actions.remove(a)


def _aim_layer(pitch=0.0, crouch=False):
    base = HL.aim_upper(pitch)

    def fn(f, pose, ctx=None):
        p = HA.Pose(pose)
        for k, v in base.items():
            if k.startswith(("hips", "thigh", "shin", "foot.", "toe", "knee_pole", "leg_ik")):
                continue
            p[k] = v
        if ctx is not None and "hips_yaw" in ctx:
            y = ctx["hips_yaw"]
            sp = p.get("spine", (0, 0, 0))
            ch = p.get("chest", (0, 0, 0))
            p["spine"] = (sp[0], sp[1] - y * 0.55, sp[2])
            p["chest"] = (ch[0], ch[1] - y * 0.45, ch[2])
        return p
    return fn


def _panic_layer():
    """Fleeing: the mocap run with the head ducked and shoulders hunched."""
    def fn(f, pose, ctx=None):
        p = HA.Pose(pose)
        p["neck"] = (14, 0, 0)
        p["head"] = (12, 0, 0)
        for side in ("L", "R"):
            p["fingers." + side] = (40, 0, 0)
        return p
    return fn


def _look_layer():
    """Idle: eyes up and a slow glance around (the performer looked at the floor)."""
    def fn(f, pose, ctx=None):
        p = HA.Pose(pose)
        t = f / HA.FPS
        look = math.sin(t * 2 * math.pi / 5.0) * 0.7 + math.sin(t * 2 * math.pi / 2.3) * 0.3
        p["neck"] = (-6 + 2 * math.sin(t * 1.1), 6 * look, 0)
        p["head"] = (-10 + 2 * math.sin(t * 1.7), 10 * look, 1.5 * math.sin(t * 0.9))
        return p
    return fn


def _fists(base=None):
    def fn(f, pose, ctx=None):
        p = base(f, pose, ctx) if base else HA.Pose(pose)
        for side in ("L", "R"):
            p["fingers." + side] = (62, 0, 0)
            p["thumb." + side] = (28, 0, 0)
        return p
    return fn


SPECS = [
    # name, bvh, kwargs
    ("idle", "077/77_02.bvh", dict(cycle=(4.0, 7.2, 0.0, 7.8), upper=_look_layer())),
    ("walk", "105/105_31.bvh", dict(cycle=(0.95, 1.4, 1.0, 12.0))),
    ("jog", "016/16_35.bvh", dict(cycle=(0.55, 0.9, 0.05, 1.33), upper=_fists())),
    ("sprint", "102/102_05.bvh", dict(cycle=(0.45, 0.8, 0.0, 0.9), upper=_fists())),
    ("panic_run", "009/09_01.bvh", dict(cycle=(0.55, 0.9, 0.0, 1.25), upper=_panic_layer())),
    ("crouch_walk", "077/77_29.bvh", dict(cycle=(1.1, 2.6, 1.0, 16.0))),
    ("aim_idle", "077/77_02.bvh", dict(cycle=(4.0, 7.2, 0.0, 7.8), upper=_aim_layer(), lower_only=True)),
    ("aim_walk_f", "105/105_31.bvh", dict(cycle=(0.95, 1.4, 1.0, 12.0), upper=_aim_layer(), lower_only=True)),
    ("aim_jog_f", "016/16_35.bvh", dict(cycle=(0.55, 0.9, 0.05, 1.33), upper=_aim_layer(), lower_only=True)),
    ("aim_walk_b", "113/113_01.bvh", dict(cycle=(0.9, 1.6, 1.0, 5.5), upper=_aim_layer(), lower_only=True, want="back")),
    ("aim_walk_l", "113/113_17.bvh", dict(cycle=(0.9, 1.8, 2.5, 12.5), upper=_aim_layer(), lower_only=True, want="left")),
    ("aim_walk_r", "113/113_17.bvh", dict(cycle=(0.9, 1.8, 2.5, 12.5), upper=_aim_layer(), lower_only=True, want="right")),
    ("jump_start", "105/105_39.bvh", dict(start_s=0.95, length=0.4, loop=False)),
    ("jump_air", "105/105_39.bvh", dict(start_s=1.6, length=0.1, loop=True, smooth=0)),
    ("jump_land", "105/105_39.bvh", dict(start_s=1.85, length=0.7, loop=False)),
    ("punch", "111/111_19.bvh", dict(start_s=0.95, length=0.8, loop=False, upper=_fists())),
    ("wave", "111/111_37.bvh", dict(cycle=(0.5, 1.4, 0.2, 2.3))),
]


def build(A, only=None):
    out = []
    for name, rel, kw in SPECS:
        if only and name not in only:
            continue
        _drop(A, name)
        act, info = MC.clip(A, name, rel, **kw)
        INFO[name] = info
        out.append(act)
    return out
