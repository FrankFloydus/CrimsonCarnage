from pathlib import Path
import json
from mesh_authoring import write_text_atomic
from terrain_sampling import sample_ground
import numpy as np
from scipy.interpolate import RegularGridInterpolator

OUT=Path(__file__).resolve().parent
VEGETATION=OUT.parent/"vegetation"
SPEC=json.loads((OUT/"site_spec.json").read_text(encoding="utf-8-sig"))
rng=np.random.default_rng(811730)
def grass_mesh(name,blades,sections):
    vertices=[];faces=[]
    for blade in range(blades):
        angle=rng.uniform(0,np.pi*2)
        length=rng.uniform(.095,.205)
        width=rng.uniform(.003,.0067)
        bend=rng.uniform(.045,.12)
        radius=rng.uniform(.025,.09)
        direction=np.array([np.cos(angle),0,np.sin(angle)])
        across=np.array([-np.sin(angle),0,np.cos(angle)])
        base=direction*radius;first=len(vertices)
        for segment in range(sections+1):
            t=segment/sections
            center=base+direction*bend*t*t+np.array([0,length*(t-.18*t*t),0])
            half=width*(1-t)**.65
            vertices.extend([center-across*half,center+direction*half*.52,center+across*half])
        for segment in range(sections):
            a=first+segment*3;b=a+3
            faces.extend([(a,b,a+1),(a+1,b,b+1),(a+1,b+1,a+2),(a+2,b+1,b+2)])
    v=np.asarray(vertices);idx=np.asarray(faces);n=np.zeros_like(v)
    tri=v[idx];nf=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0])
    for corner in range(3):np.add.at(n,idx[:,corner],nf)
    n/=np.maximum(np.linalg.norm(n,axis=1,keepdims=True),1e-9)
    target=VEGETATION/name
    temporary=target.with_suffix(".obj.tmp")
    with temporary.open("w") as f:
        f.write("o MeadowGrass\ns 1\n")
        for p in v:f.write("v %.5f %.5f %.5f\n"%tuple(p))
        for normal in n:f.write("vn %.5f %.5f %.5f\n"%tuple(normal))
        for face in idx+1:f.write("f "+" ".join(f"{i}//{i}" for i in face)+"\n")
    temporary.replace(target)
    print(name,len(faces),"triangles")
grass_mesh("grass_base_near.obj",16,3)
grass_mesh("grass_base_mid.obj",7,2)
grass_mesh("grass_base_far.obj",3,1)
data=np.load(OUT/"terrain_field.npz")
coordinates=(data["zs"],data["xs"])
sample=lambda name,q:RegularGridInterpolator(coordinates,data[name])(q)
gz,gx=np.gradient(data["height"],data["zs"],data["xs"])
sx=RegularGridInterpolator(coordinates,gx);sz=RegularGridInterpolator(coordinates,gz)
radius=float(SPEC["meadow_radius_meters"])
spacing=float(SPEC["meadow_spacing_meters"])
patch_size=float(SPEC["meadow_patch_size_meters"])
axis=np.arange(-radius,radius,spacing)
x,z=np.meshgrid(axis,axis)
x=x.ravel()+rng.uniform(-spacing*(.102/.22),spacing*(.102/.22),x.size)
z=z.ravel()+rng.uniform(-spacing*(.102/.22),spacing*(.102/.22),z.size)
q=np.stack([z,x],axis=-1)
h=sample_ground(data,x,z);meadow=sample("meadow",q);trail=sample("trail",q)
dx,dz=sx(q),sz(q)
slope=np.hypot(dx,dz)
valid=(rng.random(len(x))<np.clip(meadow*1.45,0,1))&(trail<.11)&(slope<.78)&(h>-24)
valid&=(x*x+z*z<radius*radius)
valid&=~((x>-15.35)&(x<.23)&(z>-10.0)&(z<8.5))
valid&=~((x>.60)&(x<11.90)&(z>-7.75)&(z<2.95))
x,z,h,dx,dz=x[valid],z[valid],h[valid],dx[valid],dz[valid]
groups={}
for values in zip(x,h,z,dx,dz):
    cell=(int(np.floor(values[0]/patch_size)),int(np.floor(values[2]/patch_size)))
    groups.setdefault(cell,[]).append(values)
resources=[];nodes=['[node name="MeadowCarpet" type="Node3D"]\n']
for index,(cell,items) in enumerate(sorted(groups.items())):
    cx,cz=(cell[0]+.5)*patch_size,(cell[1]+.5)*patch_size;cy=float(np.mean(np.asarray(items)[:,1]))
    buffer=[]
    for px,py,pz,dx,dz in items:
        yaw=rng.uniform(0,np.pi*2);size=rng.uniform(.82,1.23)
        normal=np.array([-dx,1,-dz]);normal/=np.linalg.norm(normal)
        along=np.array([np.cos(yaw),0,np.sin(yaw)])
        along-=normal*np.dot(along,normal);along/=np.linalg.norm(along)
        across=np.cross(along,normal)
        basis=np.stack([along*size,normal*rng.uniform(.68,1.42),across*size],axis=-1)
        shade=rng.uniform(.83,1.10)
        dry=np.clip(.40+.24*np.sin(px*.19+pz*.09)*np.sin(pz*.13-1.7)+rng.uniform(-.15,.15),0,.90)
        transform=np.column_stack([basis,[px-cx,py-cy-.018,pz-cz]])
        buffer.extend(transform.ravel().tolist()+[shade,shade,shade*.97,dry])
    resources.append(f"""
[sub_resource type="MultiMesh" id="carpet_{index}"]
resource_local_to_scene = true
transform_format = 1
use_colors = true
instance_count = {len(items)}
mesh = ExtResource("mid")
buffer = PackedFloat32Array({", ".join(f"{v:.4f}" for v in buffer)})
""")
    name=f"Meadow_{cell[0]+12:02d}_{cell[1]+12:02d}"
    nodes.append(f"""
[node name="{name}" type="MultiMeshInstance3D" parent="."]
position = Vector3({cx:.3f}, {cy:.3f}, {cz:.3f})
material_override = ExtResource("material")
extra_cull_margin = 0.4
visibility_range_end = 160.0
visibility_range_end_margin = 15.0
multimesh = SubResource("carpet_{index}")
script = ExtResource("patch")
nearby_mesh = ExtResource("near")
middle_mesh = ExtResource("mid")
distant_mesh = ExtResource("far")
nearby_distance = {float(SPEC["meadow_near_distance_meters"]):.1f}
distant_distance = {float(SPEC["meadow_distant_distance_meters"]):.1f}
patch_radius = {patch_size * .75:.1f}

[node name="WeatherResponse" type="Node" parent="{name}"]
script = ExtResource("weather")
wetting_seconds = 4.0
snow_seconds = 8.0

[node name="FoliageWind" parent="{name}" instance=ExtResource("wind")]
flexible_height = 0.18
bend_per_wind_speed = 0.003
flutter = 0.29
""")
header="""[gd_scene format=3]

[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/grass_base_near.obj" id="near"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/grass_base_mid.obj" id="mid"]
[ext_resource type="Mesh" path="res://addons/dynamic_sky/demo/landscape/vegetation/grass_base_far.obj" id="far"]
[ext_resource type="Material" path="res://addons/dynamic_sky/demo/landscape/vegetation/ground_cover_material.tres" id="material"]
[ext_resource type="Script" path="res://addons/dynamic_sky/demo/landscape/vegetation/forest_patch.gd" id="patch"]
[ext_resource type="Script" path="res://addons/dynamic_sky/surfaces/weather_surface.gd" id="weather"]
[ext_resource type="PackedScene" path="res://addons/dynamic_sky/weather/wind/foliage_wind.tscn" id="wind"]
"""
write_text_atomic(VEGETATION/"meadow_carpet.tscn",header+"".join(resources)+"".join(nodes))
print("base clumps",len(x),"patches",len(groups),"mean count per patch",len(x)/len(groups))
# Audit full eligible meadow windows away from paths, with known physical footprint.
for center in [(26,22),(-28,12),(18,35),(-32,-6),(35,-25)]:
    inside=(abs(x-center[0])<2.5)&(abs(z-center[1])<2.5)
    density=np.sum(inside)/25
    print("window",center,"clumps/m2",density,"estimated cover",1-np.exp(-density*np.pi*.145**2))



