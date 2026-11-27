"""Motion-capture retargeting: CMU Graphics Lab mocap (BVH, cgspeed conversion) -> game rig.

The CMU data "may be included in commercially-sold products" (http://mocap.cs.cmu.edu);
the clips used are listed in CLIPS below. tools/blender/fetch_mocap.sh fetches them.

Method
  * BVH parsed and forward-kinematics evaluated in numpy (no importer needed).
  * Per bone, the source's world rotation change since its rest pose is applied to our
    bone, after a "swing" that aligns our rest direction to the source's rest direction
    (CMU rests in a T-pose with splayed legs; ours is an A-pose), and after turning the
    performer's facing onto ours: R_ours(t) = Rm A_src(t) Rr^-1 S R_ours_rest.
  * Root height scales by leg-length ratio; horizontal travel is removed for locomotion
    (the game moves the character) leaving the natural sway; the measured ground speed is
    reported so playback rate can match it.
  * Loops: the most similar pose pair (feet / knees / hands relative to the pelvis, plus
    velocity, minus heading drift) inside a window is the cycle; the residual mismatch is
    spread across the cycle so it joins seamlessly. Light temporal smoothing removes
    marker jitter.
"""
import os
import math
import numpy as np
from mathutils import Matrix, Quaternion, Vector, Euler
import human_anims as HA

CMU = os.environ.get("CMU_BVH", os.path.expanduser("~/mocap/cmu/data"))
FPS = HA.FPS

MAP = {"hips": "Hips", "spine": "Spine", "chest": "Spine1", "neck": "Neck", "head": "Head"}
for _s, _S in (("L", "Left"), ("R", "Right")):
    MAP.update({"shoulder." + _s: _S + "Shoulder", "upper_arm." + _s: _S + "Arm", "forearm." + _s: _S + "ForeArm", "hand." + _s: _S + "Hand",
                "thigh." + _s: _S + "UpLeg", "shin." + _s: _S + "Leg", "foot." + _s: _S + "Foot", "toe." + _s: _S + "ToeBase"})
LIMBS = {k for k in MAP if k.endswith((".L", ".R"))}
ORDER = ["hips", "spine", "chest", "neck", "head", "shoulder.L", "upper_arm.L", "forearm.L", "hand.L", "shoulder.R", "upper_arm.R",
         "forearm.R", "hand.R", "thigh.L", "shin.L", "foot.L", "toe.L", "thigh.R", "shin.R", "foot.R", "toe.R"]
LOWER = ["hips", "thigh.L", "shin.L", "foot.L", "toe.L", "thigh.R", "shin.R", "foot.R", "toe.R"]
C = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], dtype=np.float64)   # BVH Y-up -> Blender Z-up


# ------------------------------------------------------------------ BVH
def _rot(axis, deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    if axis == "X":
        return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])
    if axis == "Y":
        return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def load_bvh(rel):
    """-> dict(names, parent, offset (N,3), frames (F, channels), chan list per joint, dt)"""
    fn = os.path.join(CMU, rel)
    names, parent, offset, chans = [], [], [], []
    ends = {}
    stack = []
    with open(fn) as f:
        lines = f.read().split("\n")
    i = 0
    end_site = False
    while i < len(lines):
        t = lines[i].split()
        i += 1
        if not t:
            continue
        if t[0] in ("ROOT", "JOINT"):
            names.append(t[1])
            parent.append(stack[-1] if stack else -1)
            offset.append([0, 0, 0])
            chans.append([])
            cur = len(names) - 1
            end_site = False
        elif t[0] == "End":
            end_site = True
        elif t[0] == "{":
            stack.append(-2 if end_site else cur)
        elif t[0] == "}":
            stack.pop()
            if stack and stack[-1] == -2:
                pass
            end_site = False
        elif t[0] == "OFFSET" and not end_site:
            offset[cur] = [float(x) for x in t[1:4]]
        elif t[0] == "OFFSET" and end_site:
            ends[cur] = [float(x) for x in t[1:4]]
        elif t[0] == "CHANNELS":
            chans[cur] = t[2:]
        elif t[0] == "MOTION":
            break
    # stack entries of -2 (end sites) must not become parents
    parent = [p if p != -2 else -1 for p in parent]
    nfr = int(lines[i].split()[1])
    dt = float(lines[i + 1].split()[2])
    data = np.array([[float(x) for x in l.split()] for l in lines[i + 2:i + 2 + nfr] if l.strip()])
    return {"names": names, "parent": parent, "offset": np.array(offset), "chans": chans, "frames": data, "dt": dt, "ends": ends}


def fk(b, step):
    """World rotations (F, N, 3, 3) and positions (F, N, 3) in Blender axes, sampled every
    `step` source frames."""
    names, parent, off, chans = b["names"], b["parent"], b["offset"], b["chans"]
    data = b["frames"][::step]
    F, N = len(data), len(names)
    R = np.zeros((F, N, 3, 3))
    P = np.zeros((F, N, 3))
    col = 0
    cols = []
    for j in range(N):
        cols.append(col)
        col += len(chans[j])
    for fi in range(F):
        row = data[fi]
        for j in range(N):
            c0 = cols[j]
            local = np.eye(3)
            pos = off[j].copy()
            for k, ch in enumerate(chans[j]):
                v = row[c0 + k]
                if ch.endswith("position"):
                    pos["XYZ".index(ch[0])] = v if parent[j] < 0 else pos["XYZ".index(ch[0])]
                else:
                    local = local @ _rot(ch[0], v)
            p = parent[j]
            if p < 0:
                R[fi, j] = local
                P[fi, j] = pos
            else:
                R[fi, j] = R[fi, p] @ local
                P[fi, j] = P[fi, p] + R[fi, p] @ off[j]
    # to Blender axes: v' = C v, R' = C R C^T
    R = np.einsum("ab,fnbc,dc->fnad", C, R, C)
    P = np.einsum("ab,fnb->fna", C, P)
    return R, P


def rest_dirs(b):
    """Rest direction (Blender axes) of each joint toward its (first) child."""
    out = {}
    for j, n in enumerate(b["names"]):
        v = None
        k = j
        while v is None or np.linalg.norm(v) < 1e-6:
            kids = [c for c, p in enumerate(b["parent"]) if p == k]
            if kids:
                k = kids[0]
                v = C @ b["offset"][k]
            elif k in b["ends"]:
                v = C @ np.array(b["ends"][k])
                break
            else:
                break
        if v is not None and np.linalg.norm(v) > 1e-9:
            out[n] = v / np.linalg.norm(v)
    return out


def mirror(b_R, b_P, names):
    """Left/right mirrored motion (x -> -x), joints swapped."""
    M = np.diag([-1.0, 1.0, 1.0])
    idx = {n: i for i, n in enumerate(names)}
    perm = []
    for n in names:
        m = n.replace("Left", "#").replace("Right", "Left").replace("#", "Right")
        m = m.replace("LHip", "#").replace("RHip", "LHip").replace("#", "RHip").replace("LThumb", "#").replace("RThumb", "LThumb").replace("#", "RThumb")
        perm.append(idx.get(m, idx[n]))
    R = np.einsum("ab,fnbc,cd->fnad", M, b_R[:, perm], M)
    P = b_P[:, perm] * np.array([-1.0, 1.0, 1.0])
    return R, P


# ------------------------------------------------------------------ analysis
def heading(P, idx):
    """Facing direction per frame (unit xy) from the hip joints: forward = left x up."""
    left = P[:, idx["LeftUpLeg"]] - P[:, idx["RightUpLeg"]]
    fwd = np.cross(left, np.array([0, 0, 1.0]))
    fwd[:, 2] = 0
    return fwd / np.maximum(np.linalg.norm(fwd, axis=1, keepdims=True), 1e-9)


def _yaw_to(v, target=(0.0, -1.0)):
    a = math.atan2(v[1], v[0])
    b = math.atan2(target[1], target[0])
    return b - a


def Rz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])


def features(R, P, idx):
    hd = heading(P, idx)
    yaw = np.arctan2(hd[:, 1], hd[:, 0])
    feats = []
    for fi in range(len(P)):
        rz = Rz(-yaw[fi])
        root = P[fi, idx["Hips"]]
        f = [rz @ (P[fi, idx[j]] - root) for j in ("LeftFoot", "RightFoot", "LeftLeg", "RightLeg", "LeftHand", "RightHand", "LeftToeBase", "RightToeBase")]
        feats.append(np.concatenate(f + [[root[2]]]))
    feats = np.array(feats)
    vel = np.zeros((len(P), 3))
    vel[1:] = P[1:, idx["Hips"]] - P[:-1, idx["Hips"]]
    vel[0] = vel[1]
    vloc = np.array([Rz(-yaw[i]) @ vel[i] for i in range(len(P))])
    return feats, vloc, yaw


def find_cycle(R, P, idx, lo, hi, window, scale):
    """Best loop (start, length) in sample frames."""
    feats, vloc, yaw = features(R, P, idx)
    a, b = window
    a = max(0, a)
    b = min(len(P) - 1, b)
    best = (1e18, a, lo)
    for s in range(a, b):
        for L in range(lo, hi + 1):
            e = s + L
            if e > b:
                break
            c = np.sum((feats[s] - feats[e]) ** 2) / (scale * scale) + 40.0 * np.sum((vloc[s] - vloc[e]) ** 2) / (scale * scale)
            dy = abs(math.remainder(yaw[e] - yaw[s], math.tau))
            c += 30.0 * dy * dy
            if c < best[0]:
                best = (c, s, L)
    return best[1], best[2], best[0]


# ------------------------------------------------------------------ retarget
class Retarget:
    def __init__(self, A):
        self.A = A
        self.rest = A.rest
        legs = (self.rest["shin.L"].to_translation() - self.rest["thigh.L"].to_translation()).length + \
               (self.rest["foot.L"].to_translation() - self.rest["shin.L"].to_translation()).length
        self.our_leg = legs
        self.R0 = {b: np.array(self.rest[b].to_3x3()) for b in MAP}

    def solve(self, b, R, P, mirror_lr=False):
        """Per-frame armature-space rotations for our bones + hips position. Returns
        (rot: {bone: (F,3,3)}, hips (F,3), speed m/s, k)"""
        names = b["names"]
        idx = {n: i for i, n in enumerate(names)}
        off = b["offset"]
        src_leg = np.linalg.norm(off[idx["LeftLeg"]]) + np.linalg.norm(off[idx["LeftFoot"]])
        k = self.our_leg / src_leg
        dirs = rest_dirs(b)
        # rest facing of the source (T-pose) and of the motion (mean over the clip)
        rest_left = C @ (off[idx["LeftUpLeg"]] - off[idx["RightUpLeg"]])
        rest_fwd = np.cross(rest_left, [0, 0, 1.0])
        Rr = Rz(_yaw_to(rest_fwd))
        hd = heading(P, idx).mean(0)
        Rm = Rz(_yaw_to(hd))
        out = {}
        for ob, sb in MAP.items():
            R0 = self.R0[ob]
            if ob in LIMBS:
                d_ours = R0 @ np.array([0, 1.0, 0])
                d_src = Rr @ dirs[sb]
                S = np.array(Vector(d_ours).rotation_difference(Vector(d_src)).to_matrix())
            else:
                S = np.eye(3)
            A_t = R[:, idx[sb]]
            M = Rr.T @ S @ R0
            out[ob] = np.einsum("ab,fbc,cd->fad", Rm, A_t, M)
        hips = np.array([Rm @ p for p in P[:, idx["Hips"]]]) * k
        return out, hips, k, idx

    def to_local(self, rot, f):
        """Armature-space rotations at frame f -> local pose quaternions (parents first)."""
        loc = {}
        world = {}
        for ob in ORDER:
            Rb = rot[ob][f]
            world[ob] = Rb
            bone = self.A.rig.data.bones[ob]
            R0 = self.R0[ob]
            if bone.parent is None:
                Q = R0.T @ Rb
            else:
                p = bone.parent.name
                Rp = world.get(p)
                if Rp is None:
                    Rp = np.array(self.rest[p].to_3x3())
                Rp0 = np.array(self.rest[p].to_3x3())
                Q = R0.T @ Rp0 @ Rp.T @ Rb
            u, _, vt = np.linalg.svd(Q)      # re-orthonormalise
            loc[ob] = Matrix((u @ vt).tolist()).to_quaternion()
        return loc


def _qavg(qs, ws):
    ref = qs[0]
    acc = np.zeros(4)
    for q, w in zip(qs, ws):
        v = np.array([q.w, q.x, q.y, q.z])
        if np.dot(v, [ref.w, ref.x, ref.y, ref.z]) < 0:
            v = -v
        acc += v * w
    acc /= np.linalg.norm(acc)
    return Quaternion(acc)


def clip(A, name, rel, start_s=None, length=None, loop=True, cycle=None, step=None, mirror_lr=False, inplace=True,
         upper=None, lower_only=False, keep_travel=0.0, smooth=1, extra=None, root_scale=1.0, hold_end=0, want=None):
    """Retarget a BVH segment into clip `name`.
      cycle=(min_s, max_s, window_from_s, window_to_s): auto-detect a loop
      start_s/length: explicit segment (seconds)
      upper(f, pose) -> pose: keyed upper-body pose layered per frame (bones it sets win)
      lower_only: take only pelvis+legs from the mocap (upper body comes from `upper`)
    Returns (action, info dict with ground speed)"""
    b = load_bvh(rel)
    src_fps = 1.0 / b["dt"]
    step = step or max(1, int(round(src_fps / FPS)))
    R, P = fk(b, step)
    if mirror_lr:
        R, P = mirror(R, P, b["names"])
    rt = Retarget(A)
    idx = {n: i for i, n in enumerate(b["names"])}
    sfps = src_fps / step
    if cycle:
        lo, hi = int(cycle[0] * sfps), int(cycle[1] * sfps)
        w0, w1 = int(cycle[2] * sfps), int(cycle[3] * sfps)
        src_leg = np.linalg.norm(b["offset"][idx["LeftLeg"]]) + np.linalg.norm(b["offset"][idx["LeftFoot"]])
        s0, L, cost = find_cycle(R, P, idx, lo, hi, (w0, w1), src_leg)
    else:
        s0 = int((start_s or 0.0) * sfps)
        L = int(length * sfps) if length else len(P) - s0 - 1
        cost = 0.0
    seg = slice(s0, s0 + L + 1)
    Rs, Ps = R[seg], P[seg]
    rot, hips, k, _ = rt.solve(b, Rs, Ps)
    n = len(Ps)
    # travel: remove the mean horizontal velocity (in-place cycles), keep sway
    disp = hips[-1] - hips[0]
    speed = math.hypot(disp[0], disp[1]) / ((n - 1) / sfps)
    # strafes: our left is +X, forward -Y; mirror the performance if it goes the other way
    if want in ("left", "right") and ((disp[0] > 0) != (want == "left")) and not mirror_lr:
        return clip(A, name, rel, start_s, length, loop, cycle, step, True, inplace, upper, lower_only, keep_travel, smooth, extra, root_scale, hold_end, want)
    t = np.arange(n) / max(1, n - 1)
    if inplace:
        hips[:, 0] -= disp[0] * t * (1.0 - keep_travel)
        hips[:, 1] -= disp[1] * t * (1.0 - keep_travel)
    hips[:, 0] -= hips[0, 0] if not inplace else hips[:, 0].mean()
    hips[:, 1] -= hips[0, 1] if not inplace else hips[:, 1].mean()
    hips[:, :2] *= root_scale
    # ground: lowest toe / foot over the segment sits where ours does at rest
    lowest = min(Ps[:, idx[j], 2].min() for j in ("LeftToeBase", "RightToeBase")) * k
    hips[:, 2] = hips[:, 2] - lowest + A.rest["toe.L"].to_translation().z
    # per-frame local rotations
    locs = [rt.to_local(rot, f) for f in range(n)]
    # loop closure: spread the end/start mismatch over the cycle
    if loop:
        for ob in ORDER:
            q0, qn = locs[0][ob], locs[-1][ob]
            d = qn.rotation_difference(q0)
            for f in range(n):
                locs[f][ob] = locs[f][ob] @ Quaternion((1, 0, 0, 0)).slerp(d, f / (n - 1))
        dz = hips[-1] - hips[0]
        hips -= np.outer(t, dz)
    # temporal smoothing (wraps for loops)
    for _ in range(smooth):
        new = []
        for f in range(n):
            a = f - 1 if f > 0 else (n - 2 if loop else 0)
            c = f + 1 if f < n - 1 else (1 if loop else n - 1)
            new.append({ob: _qavg([locs[f][ob], locs[a][ob], locs[c][ob]], [0.5, 0.25, 0.25]) for ob in ORDER})
        locs = new
    # resample to the game's frame rate
    dur = (n - 1) / sfps
    frames = max(2, int(round(dur * FPS)))
    A.begin(name)
    pb = A.pb
    ik_off = HA.Pose()
    rest_pose = HA.stand_pose()
    for kk in ("fingers.L", "fingers.R", "thumb.L", "thumb.R"):
        if kk in rest_pose:
            ik_off[kk] = rest_pose[kk]
    ik_off["arm_ik.L"] = 0.0
    ik_off["arm_ik.R"] = 0.0
    ik_off["leg_ik"] = 0.0
    prev = {}
    for fo in range(frames + (0 if loop else 1)):
        x = fo / FPS * sfps
        i0 = min(int(x), n - 1)
        i1 = min(i0 + 1, n - 1)
        w = x - i0
        pose = HA.Pose(ik_off)
        if upper is not None:
            qh = locs[i0]["hips"].slerp(locs[i1]["hips"], w)
            pose = upper(fo, pose, {"hips_yaw": math.degrees(qh.to_euler('XYZ').y)})
        A.apply(pose, fo)
        for ob in ORDER:
            if lower_only and ob not in LOWER:
                continue
            if ob in pose and not isinstance(pose[ob], dict):
                continue        # layered keyed pose overrides this bone
            q = locs[i0][ob].slerp(locs[i1][ob], w)
            e = q.to_euler('XYZ', prev.get(ob)) if ob in prev else q.to_euler('XYZ')
            prev[ob] = e
            pb[ob].rotation_euler = e
            pb[ob].keyframe_insert("rotation_euler", frame=fo)
        hp = Vector(hips[i0] * (1 - w) + hips[i1] * w)
        pb["hips"].location = A._local_offset("hips", hp - A.rest["hips"].to_translation())
        pb["hips"].keyframe_insert("location", frame=fo)
        if extra is not None:
            extra(fo, frames)
    act = A.finish(name, frames if loop else frames + 1 + hold_end, loop)
    info = {"speed": round(speed, 3), "frames": frames, "src": rel, "cycle_cost": round(float(cost), 3), "k": round(k, 3)}
    act["speed"] = info["speed"]
    print("  mocap %-12s %-14s %3d frames  speed %.2f m/s  cost %.2f" % (name, rel, frames, speed, cost))
    return act, info
