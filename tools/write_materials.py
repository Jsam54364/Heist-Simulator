"""Writes the starter material library (assets/materials/*.tres).
Each is a normal Godot material: open and tweak them in the editor, or swap
the textures for hand-made PBR sets without touching code."""
import os
M = 'assets/materials'
os.makedirs(M, exist_ok=True)

def orm(name, tex, vc=False, rough_mult=None, extra=''):
    t = f'res://assets/textures/{tex}'
    s = f'''[gd_resource type="ORMMaterial3D" load_steps=4 format=3]

[ext_resource type="Texture2D" path="{t}_albedo.png" id="1_alb"]
[ext_resource type="Texture2D" path="{t}_orm.png" id="2_orm"]
[ext_resource type="Texture2D" path="{t}_normal.png" id="3_nrm"]

[resource]
resource_name = "{name}"
vertex_color_use_as_albedo = {str(vc).lower()}
vertex_color_is_srgb = true
albedo_texture = ExtResource("1_alb")
orm_texture = ExtResource("2_orm")
normal_enabled = true
normal_scale = 1.0
normal_texture = ExtResource("3_nrm")
ao_enabled = true
ao_light_affect = 0.25
texture_filter = 5
{extra}'''
    open(f'{M}/{name}.tres', 'w').write(s)

orm('facade_stucco', 'facade_stucco', True)
orm('facade_brick', 'facade_brick', True)
orm('facade_office', 'facade_office', True)
orm('facade_glass', 'facade_glass', True)
orm('shopfront', 'shopfront', True)
orm('asphalt', 'asphalt')
orm('sidewalk', 'sidewalk')
orm('roof_gravel', 'roof_gravel')
orm('sand', 'sand')
orm('grass', 'grass')
orm('wood_planks', 'wood_planks', True)
orm('marble', 'marble')
orm('carpet', 'carpet')
orm('checker_floor', 'checker_floor')
orm('plaster', 'plaster', True)
orm('concrete', 'concrete', True)
orm('metal_brushed', 'metal_brushed', True)

def std(name, body, tex=None):
    head = '[gd_resource type="StandardMaterial3D" load_steps=2 format=3]\n\n' if tex else '[gd_resource type="StandardMaterial3D" format=3]\n\n'
    if tex:
        head += f'[ext_resource type="Texture2D" path="res://assets/textures/{tex}.png" id="1_t"]\n\n'
    open(f'{M}/{name}.tres', 'w').write(head + f'[resource]\nresource_name = "{name}"\n' + body)

std('awning', 'vertex_color_use_as_albedo = true\nvertex_color_is_srgb = true\nalbedo_texture = ExtResource("1_t")\nroughness = 0.85\ncull_mode = 2\ntexture_filter = 5\n', 'awning_albedo')
std('crosswalk', 'transparency = 1\nalbedo_texture = ExtResource("1_t")\nroughness = 0.8\ntexture_filter = 5\n', 'crosswalk_albedo')
std('signs', 'albedo_texture = ExtResource("1_t")\nroughness = 0.5\nemission_enabled = true\nemission_energy_multiplier = 0.45\nemission_texture = ExtResource("1_t")\ntexture_filter = 5\n', 'signs_atlas')
std('ads', 'albedo_texture = ExtResource("1_t")\nroughness = 0.45\nemission_enabled = true\nemission_energy_multiplier = 0.6\nemission_texture = ExtResource("1_t")\ntexture_filter = 5\n', 'ads_atlas')
std('paint', 'vertex_color_use_as_albedo = true\nvertex_color_is_srgb = true\nroughness = 0.7\n')
std('paint_gloss', 'vertex_color_use_as_albedo = true\nvertex_color_is_srgb = true\nroughness = 0.28\nmetallic = 0.25\n')
std('leaf', 'vertex_color_use_as_albedo = true\nvertex_color_is_srgb = true\nroughness = 0.75\ncull_mode = 2\nbacklight_enabled = true\nbacklight = Color(0.25, 0.4, 0.1, 1)\n')
std('trunk', 'albedo_color = Color(0.54, 0.42, 0.28, 1)\nroughness = 0.95\n')
std('lamp_glow', 'albedo_color = Color(1, 0.96, 0.82, 1)\nemission_enabled = true\nemission = Color(1, 0.93, 0.75, 1)\nemission_energy_multiplier = 3.0\n')
std('light_panel', 'albedo_color = Color(1, 1, 0.97, 1)\nemission_enabled = true\nemission = Color(1, 0.98, 0.92, 1)\nemission_energy_multiplier = 1.6\n')
std('window_glass', 'transparency = 1\nalbedo_color = Color(0.62, 0.8, 0.95, 0.22)\nroughness = 0.04\nmetallic = 0.35\n')
std('line_white', 'albedo_color = Color(0.92, 0.92, 0.9, 1)\nroughness = 0.7\n')
std('line_yellow', 'albedo_color = Color(0.88, 0.7, 0.16, 1)\nroughness = 0.7\n')
print('materials written')
