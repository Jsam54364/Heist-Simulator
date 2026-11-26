"""Writes Godot .import settings so textures are VRAM-compressed with mipmaps
(needed for good-looking, light mobile builds) and loop sounds loop."""
import os, glob, sys
FORCE = '--force' in sys.argv  # by default keep existing .import files (and their UIDs)
for p in glob.glob('assets/textures/*.png'):
    if p.endswith('_array.png'):
        continue  # Texture2DArrays: their .import is written by gen_city_arrays.py
    if os.path.exists(p + '.import') and not FORCE:
        continue
    normal = p.endswith('_normal.png')
    with open(p + '.import', 'w') as f:
        f.write('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n[params]\n\n'
                f'compress/mode=2\ncompress/high_quality=false\ncompress/normal_map={1 if normal else 2}\n'
                'mipmaps/generate=true\nroughness/mode=0\nprocess/fix_alpha_border=true\ndetect_3d/compress_to=0\n')
for p in glob.glob('assets/audio/*.wav'):
    if os.path.exists(p + '.import') and not FORCE:
        continue
    loop = '_loop' in p
    with open(p + '.import', 'w') as f:
        f.write('[remap]\n\nimporter="wav"\ntype="AudioStreamWAV"\n\n[params]\n\n'
                f'edit/loop_mode={2 if loop else 1}\nedit/loop_begin=0\nedit/loop_end=-1\ncompress/mode=0\n')
print('imports written')
