from pathlib import Path
from terrain_sampling import sample_ground
import json
import numpy as np
from scipy.interpolate import RegularGridInterpolator

out=Path(__file__).resolve().parent
root=out.parent/"vegetation"
spec=json.loads((out/"site_spec.json").read_text(encoding="utf-8-sig"))
spacing=float(spec["accent_spacing_meters"])
rng=np.random.default_rng(730391)
for level,blade_count,sections in [("near",29,3),("mid",12,2),("far",4,1)]:
    vertices=[];faces=[]
    blade_rng=np.random.default_rng(730391)
    for blade in range(blade_count):
        angle=blade_rng.uniform(0,np.pi*2)
        length=blade_rng.uniform(.27,.68)
        width=blade_rng.uniform(.0045,.012)
        bend=blade_rng.uniform(.09,.27)
        radius=blade_rng.uniform(.015,.135)
        along=np.array([np.cos(angle),0,np.sin(angle)])
        across=np.array([-np.sin(angle),0,np.cos(angle)])
        base=along*radius;first=len(vertices)
        for segment in range(sections+1):
            t=segment/sections
            center=base+along*bend*t*t+np.array([0,length*(t-.17*t*t),0])
            half=width*(1-t)**.7
            fold=along*half*.42
            vertices.extend([center-across*half,center+fold,center+across*half])
        for segment in range(sections):
            a=first+segment*3;b=a+3
            faces.extend([(a,b,a+1),(a+1,b,b+1),(a+1,b+1,a+2),(a+2,b+1,b+2)])
    v=np.asarray(vertices);idx=np.asarray(faces)
    n=np.zeros_like(v);tri=v[idx];nf=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0])
    for corner in range(3):np.add.at(n,idx[:,corner],nf)
    n/=np.maximum(np.linalg.norm(n,axis=1,keepdims=True),1e-9)
    filename="grass_tuft.obj" if level=="near" else "grass_tuft_"+level+".obj"
    with (root/filename).open("w") as f:
        f.write("o AlpineGrassTuft\ns 1\n")
        for p in v:f.write("v %.5f %.5f %.5f\n"%tuple(p))
        for normal in n:f.write("vn %.5f %.5f %.5f\n"%tuple(normal))
        for face in idx+1:f.write("f "+" ".join(f"{i}//{i}" for i in face)+"\n")
    print(filename,len(faces),"triangles")
data=np.load(out/"terrain_field.npz")
coords=(data["zs"],data["xs"])
field=lambda name,q:RegularGridInterpolator(coords,data[name])(q)
gz,gx=np.gradient(data["height"],data["zs"],data["xs"])
sx=RegularGridInterpolator(coords,gx);sz=RegularGridInterpolator(coords,gz)
axis=np.arange(-210,211,spacing)
x,z=np.meshgrid(axis,axis)
x=x.ravel()+rng.uniform(-.27,.27,x.size);z=z.ravel()+rng.uniform(-.27,.27,z.size)
q=np.stack([z,x],axis=-1)
h=sample_ground(data,x,z);meadow=field("meadow",q);trail=field("trail",q)
slope=np.hypot(sx(q),sz(q))
distance=np.hypot(x,z)
spacing_probability=np.where(distance<85,1.,(spacing/1.2)**2)
valid=(rng.random(len(x))<meadow*.82*spacing_probability)&(trail<.13)&(slope<.75)&(h>-24)
valid&=~((x>-15.3)&(x<.18)&(z>-9.95)&(z<8.45))
valid&=~((x>.65)&(x<11.85)&(z>-7.7)&(z<2.9))
x,z,h=x[valid],z[valid],h[valid]
groups={}
for px,pz,py in zip(x,z,h):
    cell=(int(np.floor(px/16)),int(np.floor(pz/16)))
    groups.setdefault(cell,[]).append((px,py-.018,pz))
resources=[];nodes=['[node name="AlpineGroundCover" type="Node3D"]\n']
for index,(cell,items) in enumerate(sorted(groups.items())):
    cx,cz=(cell[0]+.5)*16,(cell[1]+.5)*16;cy=float(np.mean(np.asarray(items)[:,1]))
    buffer=[]
    for px,py,pz in items:
        yaw=rng.uniform(0,np.pi*2);size=rng.uniform(.70,1.34)
        c,s=np.cos(yaw)*size,np.sin(yaw)*size
        shade=rng.uniform(.82,1.06)
        dry=np.clip(.35+.27*np.sin(px*.19+pz*.13)+rng.uniform(-.22,.22),0,1)
        buffer.extend([c,0,s,px-cx,0,size,0,py-cy,-s,0,c,pz-cz,shade,shade,shade*.94,dry])
    resources.append(f"""
[sub_resource type="MultiMesh" id="cover_{index}"]
resource_local_to_scene = true
transform_format = 1
use_colors = true
instance_count = {len(items)}
mesh = ExtResource("mesh")
buffer = PackedFloat32Array({", ".join(f"{v:.4f}" for v in buffer)})
""")
    name=f"Cover_{cell[0]+12:02d}_{cell[1]+12:02d}"
    nodes.append(f"""
[node name="{name}" type="MultiMeshInstance3D" parent="."]
position = Vector3({cx:.3f}, {cy:.3f}, {cz:.3f})
material_override = ExtResource("material")
extra_cull_margin = 0.5
visibility_range_end = 150.0
visibility_range_end_margin = 18.0
script = ExtResource("patch")
nearby_mesh = ExtResource("mesh")
middle_mesh = ExtResource("mid")
distant_mesh = ExtResource("far")
nearby_distance = 22.0
distant_distance = 100.0
patch_radius = 12.0
multimesh = SubResource("cover_{index}")

[node name="WeatherResponse" type="Node" parent="{name}"]
script = ExtResource("weather")
wetting_seconds = 4.0
snow_seconds = 8.0

[node name="FoliageWind" parent="{name}" instance=ExtResource("wind")]
flexible_height = 0.55
bend_per_wind_speed = 0.004
flutter = 0.34
""")
header="""[gd_scene format=3]

[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/grass_tuft.obj" id="mesh"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/grass_tuft_mid.obj" id="mid"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/grass_tuft_far.obj" id="far"]
[ext_resource type="Script" path="res://addons/dynamic_sky/demo/landscape/vegetation/forest_patch.gd" id="patch"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/landscape/vegetation/ground_cover_material.tres" id="material"]
[ext_resource type="Script" path="res://addons/dynamic_sky/surfaces/weather_surface.gd" id="weather"]
[ext_resource type="PackedScene" path="res://addons/dynamic_sky/weather/wind/foliage_wind.tscn" id="wind"]
"""
temporary=root/"ground_cover.tscn.tmp"
temporary.write_text(header+"".join(resources)+"".join(nodes),encoding="utf-8")
temporary.replace(root/"ground_cover.tscn")
print("grass",len(x),"tufts",len(groups),"patches")

