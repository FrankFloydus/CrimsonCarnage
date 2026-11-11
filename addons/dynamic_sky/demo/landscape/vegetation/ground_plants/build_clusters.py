# Bake saved local plant compositions. Existing broad meadow/forest scenes are untouched.
from pathlib import Path
import sys
import math
import numpy as np
from scipy.interpolate import RegularGridInterpolator

HERE = Path(__file__).resolve().parent
AUTHORING = HERE.parents[1] / 'authoring'
sys.path.insert(0, str(AUTHORING))
from terrain_sampling import sample_ground

FIELD = np.load(AUTHORING / 'terrain_field.npz')
TRAIL = RegularGridInterpolator((FIELD['zs'], FIELD['xs']), FIELD['trail'])
BASE = 'res://addons/dynamic_sky/demo/landscape/vegetation/ground_plants/'
PLANTS = {
    'lady_fern': ('fern', .82, .007),
    'young_fern': ('fern', .46, .005),
    'bilberry_shrub': ('shrub', .52, .003),
    'wood_sorrel': ('sorrel', .25, .003),
    'fescue_bunch': ('grass', .27, .006),
    'sedge_tussock': ('grass', .59, .007),
    'meadow_panicle': ('grass', .78, .009),
}


def build(name, centers, seed, terrace=False):
    rng = np.random.default_rng(seed)
    header = '[gd_scene format=3]\n\n'
    for plant in PLANTS:
        header += f'[ext_resource type="Mesh" path="{BASE}{plant}.obj" id="{plant}"]\n'
    header += f'[ext_resource type="Mesh" path="{BASE}lady_fern_mid.obj" id="fern_mid"]\n'
    header += f'[ext_resource type="Mesh" path="{BASE}young_fern_mid.obj" id="young_mid"]\n'
    for material in ['fern', 'grass', 'shrub', 'sorrel']:
        header += f'[ext_resource type="Material" path="{BASE}{material}_material.tres" id="{material}"]\n'
    header += '[ext_resource type="Script" path="res://addons/dynamic_sky/surfaces/weather_surface.gd" id="weather"]\n'
    header += '[ext_resource type="PackedScene" path="res://addons/dynamic_sky/weather/wind/foliage_wind.tscn" id="wind"]\n'
    header += '[ext_resource type="Script" path="res://addons/dynamic_sky/demo/landscape/vegetation/forest_patch.gd" id="lod"]\n'
    root_name = ''.join(part.title() for part in name.split('_'))
    resources, nodes = [], [f'[node name="{root_name}" type="Node3D"]\n']
    counts = {'lady_fern': 1 if terrace else 2, 'young_fern': 2, 'bilberry_shrub': 3,
              'wood_sorrel': 9, 'fescue_bunch': 12, 'sedge_tussock': 3, 'meadow_panicle': 3}
    total = 0
    for index, (cx, cz) in enumerate(centers):
        cy = float(sample_ground(FIELD, cx, cz))
        bank = f'Bank{index:02}'
        nodes += [f'\n[node name="{bank}" type="Node3D" parent="."]\nposition = Vector3({cx:.5f}, {cy:.5f}, {cz:.5f})\n']
        for plant, (material, height, bend) in PLANTS.items():
            buffer = []
            for item in range(counts[plant]):
                for attempt in range(30):
                    x, z = cx + rng.uniform(-1.6, 1.6), cz + rng.uniform(-1.25, 1.25)
                    if terrace:
                        if -15.15 < x < .10 and -9.80 < z < 8.3:
                            continue
                    elif float(TRAIL((z, x))) > .28:
                        continue
                    break
                else:
                    continue
                y = float(sample_ground(FIELD, x, z)) - .012
                scale = rng.uniform(.78, 1.20)
                if plant == 'wood_sorrel':
                    scale *= rng.uniform(.9, 1.25)
                yaw = rng.uniform(-math.pi, math.pi)
                c, s = math.cos(yaw) * scale, math.sin(yaw) * scale
                green = rng.uniform(.88, 1.05)
                buffer += [c, 0, s, x-cx, 0, scale*rng.uniform(.92,1.10), 0, y-cy,
                           -s, 0, c, z-cz, green, green*rng.uniform(.97,1.03), green*rng.uniform(.87,1.02), 1]
            count = len(buffer) // 16
            if not count:
                continue
            total += count
            resource = f'{plant}_{index}'
            resources += [f'\n[sub_resource type="MultiMesh" id="{resource}"]\nresource_local_to_scene = true\ntransform_format = 1\nuse_colors = true\ninstance_count = {count}\nmesh = ExtResource("{plant}")\nbuffer = PackedFloat32Array(' + ', '.join(f'{v:.5f}' for v in buffer) + ')\n']
            node_name = ''.join(p.title() for p in plant.split('_'))
            parent = f'{bank}/{node_name}'
            nodes += [f'\n[node name="{node_name}" type="MultiMeshInstance3D" parent="{bank}"]\nmaterial_override = ExtResource("{material}")\nmultimesh = SubResource("{resource}")\ngi_mode = 2\nlod_bias = 0.75\nextra_cull_margin = 0.30\nvisibility_range_end = 80.0\nvisibility_range_end_margin = 8.0\n']
            if plant in ['lady_fern', 'young_fern']:
                middle = 'fern_mid' if plant == 'lady_fern' else 'young_mid'
                nodes += [f'script = ExtResource("lod")\nnearby_mesh = ExtResource("{plant}")\nmiddle_mesh = ExtResource("{middle}")\ndistant_mesh = ExtResource("{middle}")\nnearby_distance = 14.0\ndistant_distance = 100.0\npatch_radius = 2.0\n']
            nodes += [f'\n[node name="Weather" type="Node" parent="{parent}"]\nscript = ExtResource("weather")\nsnow_seconds = 14.0\n']
            nodes += [f'\n[node name="FoliageWind" parent="{parent}" instance=ExtResource("wind")]\nflexible_height = {height}\nbend_per_wind_speed = {bend}\nflutter = 0.22\n']
    (HERE / (name + '.tscn')).write_text(header + ''.join(resources) + ''.join(nodes))
    print(name, total, 'saved plant instances', flush=True)


build('ridge_understory', [(11.0,21.6),(21.7,23.8),(12.2,28.0),(24.4,33.0),(13.0,39.0),(26.0,44.5),(10.5,48.0)], 55187)
build('terrace_understory', [(-15.8,-8.7),(-10.5,-10.4),(-4.6,-10.3),(.8,-6.5),(-16.1,-3.4),(-15.8,3.4)], 71513, True)
