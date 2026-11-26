"""Builds assets/textures/far_atlas.png for the far-distance HLOD shader.
4x2 cells, 256 px each, one texture tile per cell (UVs tile within a cell):
0 stucco facade, 1 brick facade, 2 office facade, 3 glass facade,
4 shopfront, 5 roof gravel, 6 sidewalk, 7 asphalt.
Run after tools/gen_assets.py (or after swapping in your own textures)."""
from PIL import Image
SRC = ['facade_stucco', 'facade_brick', 'facade_office', 'facade_glass',
       'shopfront', 'roof_gravel', 'sidewalk', 'asphalt']
C = 256
atlas = Image.new('RGB', (C * 4, C * 2))
for i, name in enumerate(SRC):
    im = Image.open(f'assets/textures/{name}_albedo.png').convert('RGB').resize((C, C), Image.LANCZOS)
    atlas.paste(im, ((i % 4) * C, (i // 4) * C))
atlas.save('assets/textures/far_atlas.png')
print('far_atlas.png written')
