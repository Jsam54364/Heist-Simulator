"""MakeHuman (CC0 assets) loader for the character build.

MakeHuman's base mesh (hm08), morph targets, game-resolution proxy meshes, clothes,
hair, eyebrows/eyelashes, skins and the default skeleton + weights are all CC0. The
assets are not stored in this repo: tools/blender/fetch_makehuman.sh sparse-clones the
data folder to MH_DATA (default ~/mh/core/data).

Pipeline:
  * base mesh + weighted macro targets (gender/age/muscle/weight/height/proportions and
    ethnicity, using MakeHuman's own interpolation rules) + optional measure targets
  * proxies / clothes / hair (.proxy / .mhclo) are fitted to the morphed base exactly as
    MakeHuman does: each vertex = barycentric mix of 3 base verts + scaled offset
  * skeleton joints = centroids of the base mesh's joint helper groups
  * skin weights come from the default rig's painted weights (default_weights.mhw),
    mapped onto our simpler game skeleton and carried to proxies through the same refs.
Coordinates: MakeHuman is Y-up, decimetres, facing +Z. We convert to Blender metres,
Z-up, facing -Y (our rig convention).
"""
import os
import json
import numpy as np

MH_DATA = os.environ.get("MH_DATA", os.path.expanduser("~/mh/core/data"))


def path(*p):
    return os.path.join(MH_DATA, *p)


def to_bl(a):
    """MakeHuman (x, y, z) dm Y-up facing +Z -> Blender m Z-up facing -Y."""
    a = np.asarray(a, dtype=np.float64)
    out = np.empty_like(a)
    out[..., 0] = a[..., 0] * 0.1
    out[..., 1] = -a[..., 2] * 0.1
    out[..., 2] = a[..., 1] * 0.1
    return out


# ------------------------------------------------------------------ obj
def load_obj(fn):
    """-> dict(v: (N,3) MH coords, uv: (M,2), faces: [[(vi, ti), ...]], groups: {name: [face idx]})"""
    vs, uvs, faces, groups = [], [], [], {}
    cur = None
    with open(fn) as f:
        for line in f:
            if line.startswith("v "):
                vs.append([float(x) for x in line.split()[1:4]])
            elif line.startswith("vt "):
                uvs.append([float(x) for x in line.split()[1:3]])
            elif line.startswith("f "):
                fv = []
                for tok in line.split()[1:]:
                    p = tok.split("/")
                    vi = int(p[0]) - 1
                    ti = int(p[1]) - 1 if len(p) > 1 and p[1] else -1
                    fv.append((vi, ti))
                if cur is not None:
                    groups.setdefault(cur, []).append(len(faces))
                faces.append(fv)
            elif line.startswith("g "):
                cur = line.split(None, 1)[1].strip()
    return {"v": np.array(vs), "uv": np.array(uvs) if uvs else np.zeros((0, 2)), "faces": faces, "groups": groups}


_BASE = None


def base():
    global _BASE
    if _BASE is None:
        _BASE = load_obj(path("3dobjs", "base.obj"))
        # vertex sets per group
        g = {}
        for name, fids in _BASE["groups"].items():
            s = set()
            for fi in fids:
                for vi, _ in _BASE["faces"][fi]:
                    s.add(vi)
            g[name] = sorted(s)
        _BASE["gverts"] = g
    return _BASE


# ------------------------------------------------------------------ targets
_TCACHE = {}


def load_target(rel):
    if rel in _TCACHE:
        return _TCACHE[rel]
    fn = path("targets", rel)
    idx, d = [], []
    if os.path.exists(fn):
        with open(fn) as f:
            for line in f:
                if not line.strip() or line[0] == "#":
                    continue
                p = line.split()
                idx.append(int(p[0]))
                d.append([float(p[1]), float(p[2]), float(p[3])])
    t = (np.array(idx, dtype=np.int64), np.array(d) if d else np.zeros((0, 3)))
    _TCACHE[rel] = t
    return t


def _pair(v, lo, mid, hi):
    """MakeHuman 3-point slider weights (min / average / max)."""
    if v < 0.5:
        return {lo: 1.0 - v * 2.0, mid: v * 2.0, hi: 0.0}
    return {lo: 0.0, mid: 1.0 - (v - 0.5) * 2.0, hi: (v - 0.5) * 2.0}


def macro_weights(p):
    """Target -> weight for MakeHuman's macro modifiers (humanmodifier.MacroModifier)."""
    g = p.get("gender", 0.5)
    a = p.get("age", 0.5)
    gw = {"female": 1.0 - g, "male": g}
    if a < 0.5:
        young = max(0.0, (a - 0.1875) * 3.2)
        aw = {"baby": max(0.0, 1.0 - a * 5.333), "child": max(0.0, min(1.0, 5.333 * a) - young), "young": young, "old": 0.0}
    else:
        old = max(0.0, a * 2.0 - 1.0)
        aw = {"baby": 0.0, "child": 0.0, "young": 1.0 - old, "old": old}
    mw = _pair(p.get("muscle", 0.5), "minmuscle", "averagemuscle", "maxmuscle")
    ww = _pair(p.get("weight", 0.5), "minweight", "averageweight", "maxweight")
    h = p.get("height", 0.5)
    hw = {"minheight": max(0.0, 1.0 - 2.0 * h), "maxheight": max(0.0, 2.0 * h - 1.0)}
    pr = p.get("proportions", 0.5)
    pw = {"uncommonproportions": max(0.0, 1.0 - 2.0 * pr), "idealproportions": max(0.0, 2.0 * pr - 1.0)}
    race = p.get("race", {"african": 1 / 3, "asian": 1 / 3, "caucasian": 1 / 3})
    out = {}

    def add(k, w):
        if w > 1e-6:
            out[k] = out.get(k, 0.0) + w
    for gn, gv in gw.items():
        for an, av in aw.items():
            for rn, rv in race.items():
                add("macrodetails/%s-%s-%s.target" % (rn, gn, an), gv * av * rv)
            for mn, mv in mw.items():
                for wn, wv in ww.items():
                    base_w = gv * av * mv * wv
                    add("macrodetails/universal-%s-%s-%s-%s.target" % (gn, an, mn, wn), base_w)
                    for hn, hv in hw.items():
                        add("macrodetails/height/%s-%s-%s-%s-%s.target" % (gn, an, mn, wn, hn), base_w * hv)
                    for pn, pv in pw.items():
                        add("macrodetails/proportions/%s-%s-%s-%s-%s.target" % (gn, an, mn, wn, pn), base_w * pv)
    return out


def morph(p):
    """Morphed base vertex positions (MakeHuman coords). p: macro params + 'extra':
    {target_rel: weight} for detail targets such as measure/measure-waist-circ-decr."""
    B = base()
    v = B["v"].copy()
    tw = macro_weights(p)
    for k, w in p.get("extra", {}).items():
        tw[k] = tw.get(k, 0.0) + w
    for rel, w in tw.items():
        idx, d = load_target(rel)
        if len(idx):
            v[idx] += d * w
    return v


# ------------------------------------------------------------------ proxies / clothes
def load_proxy(fn):
    """.proxy / .mhclo -> dict(refs: (N,3) int, w: (N,3), off: (N,3), scale: {axis: (v1, v2, d)},
    obj, delete: set of base verts, material)"""
    refs, ws, offs = [], [], []
    scale = {}
    delete = set()
    info = {"obj_file": None, "material": None, "z_depth": 50}
    mode = None
    d = os.path.dirname(fn)
    with open(fn) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            p = s.split()
            if p[0] == "verts":
                mode = "verts"
                continue
            if p[0] == "delete_verts":
                mode = "delete"
                continue
            if mode == "verts" and len(p) >= 9 and _isnum(p[0]):
                refs.append([int(p[0]), int(p[1]), int(p[2])])
                ws.append([float(p[3]), float(p[4]), float(p[5])])
                offs.append([float(p[6]), float(p[7]), float(p[8])])
                continue
            if mode == "verts" and len(p) == 1 and _isnum(p[0]):
                refs.append([int(p[0])] * 3)
                ws.append([1.0, 0.0, 0.0])
                offs.append([0.0, 0.0, 0.0])
                continue
            if mode == "delete" and _isnum(p[0]):
                i = 0
                while i < len(p):
                    if i + 2 < len(p) and p[i + 1] == "-":
                        delete.update(range(int(p[i]), int(p[i + 2]) + 1))
                        i += 3
                    else:
                        delete.add(int(p[i]))
                        i += 1
                continue
            if p[0] in ("x_scale", "y_scale", "z_scale"):
                scale[p[0][0]] = (int(p[1]), int(p[2]), float(p[3]))
            elif p[0] == "obj_file":
                info["obj_file"] = os.path.join(d, p[1])
            elif p[0] == "material":
                info["material"] = os.path.join(d, p[1])
            elif p[0] == "z_depth":
                info["z_depth"] = int(p[1])
            elif p[0] == "name":
                info["name"] = p[1]
    info.update({"refs": np.array(refs), "w": np.array(ws), "off": np.array(offs), "scale": scale, "delete": delete})
    return info


def _isnum(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def fit(proxy, bv):
    """Proxy vertex positions (MakeHuman coords) for morphed base verts bv."""
    r = proxy["refs"]
    w = proxy["w"]
    pos = bv[r[:, 0]] * w[:, 0:1] + bv[r[:, 1]] * w[:, 1:2] + bv[r[:, 2]] * w[:, 2:3]
    sc = np.ones(3)
    for ax, i in (("x", 0), ("y", 1), ("z", 2)):
        if ax in proxy["scale"]:
            a, b, d0 = proxy["scale"][ax]
            sc[i] = abs(bv[a][i] - bv[b][i]) / d0
    return pos + proxy["off"] * sc


def read_mhmat(fn):
    out = {}
    if not fn or not os.path.exists(fn):
        return out
    d = os.path.dirname(fn)
    with open(fn) as f:
        for line in f:
            p = line.strip().split(None, 1)
            if len(p) == 2 and not p[0].startswith("#"):
                out[p[0]] = p[1]
    for k in ("diffuseTexture", "normalmapTexture", "aomapTexture", "specularmapTexture"):
        if k in out:
            out[k] = os.path.join(d, os.path.basename(out[k]))
    return out


# ------------------------------------------------------------------ skeleton + weights
_SKEL = None


def skeleton():
    global _SKEL
    if _SKEL is None:
        _SKEL = json.load(open(path("rigs", "default.mhskel")))
        _SKEL["weights"] = json.load(open(path("rigs", "default_weights.mhw")))["weights"]
    return _SKEL


def joint(bv, name):
    """Centroid of a MakeHuman joint (e.g. 'upperarm01.L____head') on morphed verts."""
    vs = skeleton()["joints"][name]
    return bv[vs].mean(axis=0)


def bone_head(bv, b):
    return joint(bv, skeleton()["bones"][b]["head"])


def bone_tail(bv, b):
    return joint(bv, skeleton()["bones"][b]["tail"])


def base_weights(bone_map):
    """Per base vertex {our_bone: weight}, summing MakeHuman bones mapped by bone_map(mh_name)."""
    W = skeleton()["weights"]
    n = len(base()["v"])
    out = [dict() for _ in range(n)]
    for mb, lst in W.items():
        ob = bone_map(mb)
        if ob is None:
            continue
        for vi, w in lst:
            d = out[vi]
            d[ob] = d.get(ob, 0.0) + w
    return out


def proxy_weights(proxy, bw):
    """Carry base weights to proxy vertices through the fitting refs."""
    out = []
    for r, w in zip(proxy["refs"], proxy["w"]):
        d = {}
        for k in range(3):
            if w[k] <= 0.0:
                continue
            for b, x in bw[r[k]].items():
                d[b] = d.get(b, 0.0) + x * w[k]
        out.append(d)
    return out
