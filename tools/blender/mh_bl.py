"""Blender-side helpers for MakeHuman assets: build fitted meshes with UVs and textures."""
import os
import bpy
import bmesh
import numpy as np
import mh


def mesh_from(name, verts_bl, obj, keep_faces=None, uv_name="UVMap"):
    """Blender mesh object from fitted vertex positions + the asset obj's faces/UVs."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bv = [bm.verts.new(tuple(p)) for p in verts_bl]
    bm.verts.index_update()
    uvl = bm.loops.layers.uv.new(uv_name)
    uvs = obj["uv"]
    for fi, f in enumerate(obj["faces"]):
        if keep_faces is not None and not keep_faces(fi, f):
            continue
        idx = [vi for vi, _ in f]
        if len(set(idx)) < 3:
            continue
        try:
            face = bm.faces.new([bv[i] for i in idx])
        except ValueError:
            continue
        for loop, (vi, ti) in zip(face.loops, f):
            if ti >= 0 and len(uvs):
                loop[uvl].uv = tuple(uvs[ti])
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def image(fn):
    if not fn or not os.path.exists(fn):
        return None
    for im in bpy.data.images:
        if im.filepath == fn:
            return im
    return bpy.data.images.load(fn)


def tex_material(name, diffuse, normal=None, alpha=False, rough=0.7):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Roughness"].default_value = rough
    nt.links.new(bsdf.outputs[0], out.inputs[0])
    im = image(diffuse)
    if im:
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = im
        nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
        if alpha:
            nt.links.new(t.outputs["Alpha"], bsdf.inputs["Alpha"])
            try:
                m.blend_method = "CLIP"
            except Exception:
                pass
    if normal and os.path.exists(normal):
        nim = image(normal)
        nim.colorspace_settings.name = "Non-Color"
        t2 = nt.nodes.new("ShaderNodeTexImage")
        t2.image = nim
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(t2.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs[0], bsdf.inputs["Normal"])
    return m


def asset(kind, name):
    """(proxy dict, obj dict, mhmat dict) for e.g. ('clothes', 'male_casualsuit03')."""
    d = mh.path(kind, name)
    fn = None
    for f in os.listdir(d):
        if f.endswith(".mhclo") or f.endswith(".proxy"):
            fn = os.path.join(d, f)
    px = mh.load_proxy(fn)
    ob = mh.load_obj(px["obj_file"])
    mat = mh.read_mhmat(px["material"]) if px.get("material") else {}
    if not mat:
        for f in os.listdir(d):
            if f.endswith(".mhmat"):
                mat = mh.read_mhmat(os.path.join(d, f))
    return px, ob, mat
