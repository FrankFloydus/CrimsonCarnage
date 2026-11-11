from pathlib import Path
from mesh_authoring import write_text_atomic
from terrain_sampling import sample_ground
import numpy as np
from scipy.interpolate import RegularGridInterpolator
from scipy.spatial.transform import Rotation

OUT=Path(__file__).resolve().parent
TARGET=OUT.parent/"details/ridge_trail.tscn"
data=np.load(OUT/"terrain_field.npz")
height=RegularGridInterpolator((data["zs"],data["xs"]),data["height"])
rng=np.random.default_rng(419137)
ground=lambda x,z:float(sample_ground(data,x,z))
def transform(position,scale=(1,1,1),angles=(0,0,0)):
    basis=Rotation.from_euler("YXZ",[angles[1],angles[0],angles[2]],degrees=True).as_matrix()@np.diag(scale)
    values=list(basis.T.ravel())+list(position)
    return "Transform3D("+", ".join(f"{v:.5f}" for v in values)+")"

header="""[gd_scene format=3]

[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/details/ridge_outcrop.obj" id="outcrop"]
[ext_resource type="Shape3D" path="res://addons/dynamic_sky/demo/landscape/details/ridge_outcrop_collision.res" id="outcrop_shape"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/materials/ridge_gneiss_outcrop.tres" id="outcrop_material"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/terrace_boulder.obj" id="stone"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/materials/alpine_boulder.tres" id="stone_material"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/details/fallen_branch.obj" id="wood"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/landscape/details/deadwood_material.tres" id="wood_material"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/alpine_fern.obj" id="fern"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/low_shrub.obj" id="shrub"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/landscape/vegetation/low_shrub_material.tres" id="leaf_material"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/straw_seedheads.obj" id="seedheads"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/landscape/vegetation/seedhead_material.tres" id="seed_material"]
[ext_resource type="Script" path="res://addons/dynamic_sky/surfaces/weather_surface.gd" id="weather"]
[ext_resource type="PackedScene" path="res://addons/dynamic_sky/weather/wind/foliage_wind.tscn" id="wind"]
"""
resources=[];nodes=['[node name="RidgeTrail" type="Node3D"]\n']
outcrops=[
    ("TrailWall",32,43,(14,8.5,11),(-7,17,9)),
    ("UpperShoulder",8,66,(19,12,15),(12,-29,-8)),
    ("RidgeMass",39,132,(32,24,24),(-11,22,13)),
    ("WestFracture",-14,87,(14,9,18),(5,-19,11)),
    ("TrailBlock",19.2,30.5,(3.0,1.6,2.5),(11,41,-9)),
    ("BeddedStone",14.9,38.4,(2.1,1.0,1.7),(-7,-25,6)),
]
for name,x,z,scale,angles in outcrops:
    y=ground(x,z)+scale[1]*.23
    nodes.append(f"""
[node name="{name}" type="MeshInstance3D" parent="."]
transform = {transform((x,y,z),scale,angles)}
mesh = ExtResource("outcrop")
material_override = ExtResource("outcrop_material")

[node name="WeatherResponse" type="Node" parent="{name}"]
script = ExtResource("weather")
wetting_seconds = 5.0
snow_seconds = 8.0

[node name="Collision" type="StaticBody3D" parent="{name}"]
collision_mask = 0

[node name="Shape" type="CollisionShape3D" parent="{name}/Collision"]
shape = ExtResource("outcrop_shape")
""")
for index in range(36):
    z=rng.uniform(15,88);x=17+np.sin(z*.06)*8+rng.uniform(-5.5,5.5)
    if np.hypot(x-19.2,z-30.5)<1.7:continue
    size=rng.uniform(.12,.60)
    y=ground(x,z)+size*.12
    nodes.append(f"""
[node name="Talus{index:02d}" type="MeshInstance3D" parent="."]
transform = {transform((x,y,z),(size*1.3,size*.7,size),rng.uniform(-24,24,3))}
mesh = ExtResource("stone")
material_override = ExtResource("stone_material")

[node name="WeatherResponse" type="Node" parent="Talus{index:02d}"]
script = ExtResource("weather")
snow_seconds = 8.0
""")
for index,(x,z,yaw,size) in enumerate([(17.7,26.4,36,1.2),(22.4,35.8,-19,.8),(15.1,32.7,72,.7),(24.2,44.5,28,1.5),(11.8,54.0,-34,1.1),(13.9,23.5,8,.8)]):
    nodes.append(f"""
[node name="FallenBranch{index}" type="MeshInstance3D" parent="."]
transform = {transform((x,ground(x,z)+.035,z),(size,size,size),(0,yaw,0))}
mesh = ExtResource("wood")
material_override = ExtResource("wood_material")

[node name="WeatherResponse" type="Node" parent="FallenBranch{index}"]
script = ExtResource("weather")
snow_seconds = 8.0
""")
def plants(name,mesh,material,centers,count,scale_range,height_offset,flex,bend):
    for group_index,(cx,cz) in enumerate(centers):
        cy=ground(cx,cz);buffer=[]
        for item in range(count):
            x=cx+rng.normal(0,1.6);z=cz+rng.normal(0,1.7)
            # Keep the narrow authored walking line open.
            trail=float(RegularGridInterpolator((data["zs"],data["xs"]),data["trail"])((z,x)))
            if trail>.30:continue
            y=ground(x,z)+height_offset
            scale=rng.uniform(*scale_range);yaw=rng.uniform(0,np.pi*2)
            c,s=np.cos(yaw)*scale,np.sin(yaw)*scale
            shade=rng.uniform(.82,1.10)
            buffer.extend([c,0,s,x-cx,0,scale,0,y-cy,-s,0,c,z-cz,shade,shade,shade*.97,1])
        resource=f"{name}_{group_index}"
        resources.append(f"""
[sub_resource type="MultiMesh" id="{resource}"]
resource_local_to_scene = true
transform_format = 1
use_colors = true
instance_count = {len(buffer)//16}
mesh = ExtResource("{mesh}")
buffer = PackedFloat32Array({", ".join(f"{v:.5f}" for v in buffer)})
""")
        node=f"{name}{group_index}"
        nodes.append(f"""
[node name="{node}" type="MultiMeshInstance3D" parent="."]
position = Vector3({cx:.4f}, {cy:.4f}, {cz:.4f})
lod_bias = 0.7
material_override = ExtResource("{material}")
multimesh = SubResource("{resource}")
extra_cull_margin = 0.4

[node name="WeatherResponse" type="Node" parent="{node}"]
script = ExtResource("weather")
snow_seconds = 8.0

[node name="FoliageWind" parent="{node}" instance=ExtResource("wind")]
flexible_height = {flex}
bend_per_wind_speed = {bend}
flutter = 0.25
""")
centers=[(11.5,21),(23.5,26),(14,34),(21,43),(12,50),(31,59),(38,73),(-27,10)]
plants("Fern", "fern","leaf_material",centers,8,(.72,1.21),-.015,.55,.008)
plants("LowShrub","shrub","leaf_material",[(9,27),(27,32),(22,48),(2,53),(37,89),(-26,7)],9,(.9,1.50),-.01,.30,.002)
plants("Seedheads","seedheads","seed_material",[(13,24),(24,31),(16,44),(28,54),(22,57),(-31,8)],8,(.7,1.15),-.01,.84,.006)
write_text_atomic(TARGET,header+"".join(resources)+"".join(nodes))
print("staging scene bytes",TARGET.stat().st_size)




