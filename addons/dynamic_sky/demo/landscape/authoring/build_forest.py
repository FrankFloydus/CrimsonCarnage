from pathlib import Path
import json
from terrain_sampling import sample_ground
import numpy as np
from scipy.interpolate import RegularGridInterpolator

OUT=Path(__file__).resolve().parent
SPEC=json.loads((OUT/"site_spec.json").read_text(encoding="utf-8-sig"))
TARGET=OUT.parent/"vegetation/forest.tscn"
data=np.load(OUT/"terrain_field.npz")
rng=np.random.default_rng(937130)
patch_size=float(SPEC["forest_patch_size_meters"])
axis=np.arange(-1250,1250,float(SPEC["forest_spacing_meters"]))
x,z=np.meshgrid(axis,axis)
x=x.ravel()+rng.uniform(-2.5,2.5,x.size)
z=z.ravel()+rng.uniform(-2.5,2.5,z.size)
q=np.stack([z,x],axis=-1)
sample=lambda name:RegularGridInterpolator((data["zs"],data["xs"]),data[name])(q)
h,forest,trail=sample_ground(data,x,z),sample("forest"),sample("trail")
gz,gx=np.gradient(data["height"],data["zs"],data["xs"])
slope=RegularGridInterpolator((data["zs"],data["xs"]),np.hypot(gx,gz))(q)
valid=(rng.random(len(x))<np.clip(forest*2.35,0,1))&(slope<.90)&(h>-23)&(h<265)&(trail<.05)
valid&=np.hypot(x,z)>22
x,z,h=x[valid],z[valid],h[valid]
size=rng.uniform(1.4,2.45,len(x))*(1-.18*np.clip((h-160)/100,0,1))
yaw=rng.uniform(0,np.pi*2,len(x))
shade=rng.uniform(.72,.98,len(x))
points=np.stack([x,h-.12,z,size,yaw,shade],axis=-1)

groups={}
for p in points:
    cell=(int(np.floor(p[0]/patch_size)),int(np.floor(p[2]/patch_size)))
    groups.setdefault(cell,[]).append(p)
header="""[gd_scene format=3]

[ext_resource type="Script" path="res://addons/dynamic_sky/demo/landscape/vegetation/forest_patch.gd" id="patch"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/landscape/vegetation/spruce/spruce_material.tres" id="material"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/spruce/spruce_mid.obj" id="mid"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/spruce/spruce_far.obj" id="far"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/spruce/spruce_distant.obj" id="distant"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/spruce/spruce_open_mid.obj" id="open_mid"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/spruce/spruce_open_far.obj" id="open_far"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/spruce/spruce_open_distant.obj" id="open_distant"]
[ext_resource type="Script" path="res://addons/dynamic_sky/surfaces/weather_surface.gd" id="weather"]
[ext_resource type="PackedScene" path="res://addons/dynamic_sky/weather/wind/foliage_wind.tscn" id="wind"]
"""
resources=[];nodes=['[node name="SpruceForest" type="Node3D"]\n']
for index,(cell,items) in enumerate(sorted(groups.items())):
    cx,cz=(cell[0]+.5)*patch_size,(cell[1]+.5)*patch_size
    mature=(cell[0]*13+cell[1]*7)%5!=0
    near_id="open_mid" if mature else "mid"
    middle_id="open_far" if mature else "far"
    distant_id="open_distant" if mature else "distant"
    cy=float(np.mean(np.array(items)[:,1]))
    buffer=[]
    for x,y,z,size,yaw,shade in items:
        c,s=np.cos(yaw),np.sin(yaw)
        width=size*.79
        buffer.extend([c*width,0,s*width,x-cx,0,size,0,y-cy,-s*width,0,c*width,z-cz,shade*.93,shade,shade*.91,1])
    resources.append(f"""
[sub_resource type="MultiMesh" id="stand_{index}"]
resource_local_to_scene = true
transform_format = 1
use_colors = true
instance_count = {len(items)}
mesh = ExtResource("{middle_id}")
buffer = PackedFloat32Array({", ".join(f"{v:.4f}" for v in buffer)})
""")
    name=f"Stand_{cell[0]+20:02d}_{cell[1]+20:02d}"
    nodes.append(f"""
[node name="{name}" type="MultiMeshInstance3D" parent="."]
position = Vector3({cx:.3f}, {cy:.3f}, {cz:.3f})
material_override = ExtResource("material")
extra_cull_margin = 2.0
multimesh = SubResource("stand_{index}")
script = ExtResource("patch")
nearby_mesh = ExtResource("{near_id}")
middle_mesh = ExtResource("{middle_id}")
distant_mesh = ExtResource("{distant_id}")
nearby_distance = {float(SPEC["forest_near_distance_meters"])}
distant_distance = {float(SPEC["forest_distant_distance_meters"])}
patch_radius = 70.0

[node name="WeatherResponse" type="Node" parent="{name}"]
script = ExtResource("weather")
wetting_seconds = 6.0
drying_seconds = 22.0
snow_seconds = 10.0
thaw_seconds = 35.0

[node name="FoliageWind" parent="{name}" instance=ExtResource("wind")]
flexible_height = {10.2 if mature else 7.2}
bend_per_wind_speed = 0.016
flutter = 0.20
""")
temporary=TARGET.with_suffix(".tscn.tmp")
temporary.write_text(header+"".join(resources)+"\n"+"".join(nodes),encoding="utf-8")
temporary.replace(TARGET)
print(len(points),"trees",len(groups),"forest patches")



