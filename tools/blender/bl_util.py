"""Shared helpers for the Blender asset scripts (run with Blender's Python / the bpy module).

Everything in tools/blender is generated from code so the assets can be rebuilt and
tweaked without a desktop: `python tools/blender/make_all.py` (needs `pip install bpy`).
"""
import math
import bpy
import bmesh
from mathutils import Vector, Matrix, Euler, Quaternion


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    s = bpy.context.scene
    s.render.fps = 30
    s.frame_start = 0


def link(obj, coll=None):
    (coll or bpy.context.scene.collection).objects.link(obj)
    return obj


def select_only(*objs):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[-1]


def apply_modifiers(obj):
    select_only(obj)
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ev, preserve_all_data_layers=True, depsgraph=dg)
    old = obj.data
    obj.modifiers.clear()
    obj.data = me
    bpy.data.meshes.remove(old)


def mesh_from_bmesh(name, bm):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    link(obj)
    return obj


def shade_smooth(obj, angle=None):
    for p in obj.data.polygons:
        p.use_smooth = True
    if angle is not None:
        select_only(obj)
        bpy.ops.object.shade_auto_smooth(angle=math.radians(angle))


def flat(obj):
    for p in obj.data.polygons:
        p.use_smooth = False


def ensure_color(obj, name="Col"):
    me = obj.data
    if name not in me.color_attributes:
        me.color_attributes.new(name=name, type='BYTE_COLOR', domain='CORNER')
    return me.color_attributes[name]


def paint_corners(obj, fn, name="Col"):
    """fn(poly, loop_vertex_index, co) -> (r,g,b,a)"""
    attr = ensure_color(obj, name)
    me = obj.data
    for poly in me.polygons:
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            attr.data[li].color = fn(poly, vi, me.vertices[vi].co)


def solid_color(obj, rgba, name="Col"):
    paint_corners(obj, lambda p, v, c: rgba, name)


def uv_layer(obj, name):
    me = obj.data
    if name not in me.uv_layers:
        me.uv_layers.new(name=name)
    return me.uv_layers[name]


def smart_uv(obj):
    select_only(obj)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.02)
    bpy.ops.object.mode_set(mode='OBJECT')


def join(objs, name=None):
    select_only(*objs)
    bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    if name:
        o.name = name
        o.data.name = name
    return o


def material(name, color=(0.8, 0.8, 0.8, 1), rough=0.6, metal=0.0, emission=None, vcol=False):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = emission
        bsdf.inputs["Emission Strength"].default_value = 1.0
    if vcol:
        vc = nt.nodes.new("ShaderNodeVertexColor")
        vc.layer_name = "Col"
        nt.links.new(vc.outputs["Color"], bsdf.inputs["Base Color"])
    return m


def set_material(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)


def export_glb(path, objects=None, animations=True, selection=True, extra=None):
    if objects is not None:
        select_only(*objects)
    opts = dict(
        filepath=path, export_format='GLB', use_selection=selection, export_yup=True, export_apply=True,
        export_texcoords=True, export_normals=True, export_vertex_color='ACTIVE', export_all_vertex_colors=True,
        export_materials='EXPORT', export_animations=animations, export_skins=True, export_def_bones=True,
        export_morph=False, export_lights=False, export_cameras=False, export_extras=False,
        export_tangents=False, export_optimize_animation_size=True, export_force_sampling=True,
        export_frame_step=1, export_animation_mode='ACTIONS', export_anim_slide_to_zero=True,
        export_reset_pose_bones=True, export_influence_nb=4,
    )
    if extra:
        opts.update(extra)
    bpy.ops.export_scene.gltf(**opts)


def render_preview(path, objects_center=(0, 0, 0.9), dist=3.2, size=(360, 480), yaw=25, pitch=8, ortho=None):
    """Quick Workbench render used to eyeball models and poses."""
    s = bpy.context.scene
    s.render.engine = 'BLENDER_WORKBENCH'
    s.display.shading.light = 'STUDIO'
    s.display.shading.color_type = 'VERTEX'
    s.display.shading.show_cavity = True
    s.display.shading.show_shadows = True
    s.render.resolution_x, s.render.resolution_y = size
    cam = bpy.data.objects.get("PreviewCam")
    if cam is None:
        cam = bpy.data.objects.new("PreviewCam", bpy.data.cameras.new("PreviewCam"))
        link(cam)
    c = Vector(objects_center)
    a = math.radians(yaw)
    p = math.radians(pitch)
    cam.location = c + Vector((math.sin(a) * math.cos(p), -math.cos(a) * math.cos(p), math.sin(p))) * dist
    cam.rotation_euler = (c - cam.location).to_track_quat('-Z', 'Y').to_euler()
    if ortho:
        cam.data.type = 'ORTHO'
        cam.data.ortho_scale = ortho
    else:
        cam.data.type = 'PERSP'
        cam.data.lens = 50
    s.camera = cam
    s.render.filepath = path
    bpy.ops.render.render(write_still=True)
