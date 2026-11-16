"""Build the saved West Ridge landform and its shared biome field."""

from pathlib import Path
import json
import numpy as np
from scipy.interpolate import RegularGridInterpolator,CubicSpline,PchipInterpolator
from scipy.ndimage import distance_transform_edt
from terrain_processes import breach_depressions
from terrain_processes_hillslope import erode_bedrock

OUT=Path(__file__).resolve().parent
SPEC=json.loads((OUT/"site_spec.json").read_text())
LANDFORM=json.loads((OUT/"landform_spec.json").read_text())
SEED=int(SPEC["terrain_seed"])
extent=float(SPEC["domain_half_extent_meters"])
step=float(SPEC["erosion_grid_step_meters"])
axis=np.arange(-extent,extent+.1,step)
x,z=np.meshgrid(axis,axis)

def smooth(a,b,v):
    t=np.clip((v-a)/(b-a),0,1);return t*t*(3-2*t)
def hash2(ix,iz):
    v=np.sin(ix*127.1+iz*311.7+SEED*.00013)*43758.5453
    return v-np.floor(v)
def gradient_noise(px,pz):
    ix,iz=np.floor(px),np.floor(pz);tx,tz=px-ix,pz-iz
    u=tx*tx*tx*(tx*(tx*6-15)+10);v=tz*tz*tz*(tz*(tz*6-15)+10)
    dots=[]
    for dx,dz in [(0,0),(1,0),(0,1),(1,1)]:
        angle=hash2(ix+dx,iz+dz)*np.pi*2
        dots.append(np.cos(angle)*(tx-dx)+np.sin(angle)*(tz-dz))
    return ((dots[0]*(1-u)+dots[1]*u)*(1-v)+(dots[2]*(1-u)+dots[3]*u)*v)*1.65
def fbm(px,pz):
    value=np.zeros(np.broadcast(px,pz).shape)
    for f,w in [(1,.56),(2.07,.25),(4.31,.13),(9.17,.06)]:
        value+=gradient_noise(px*f+f*5.1,pz*f-f*2.7)*w
    return value

def ridged_multifractal(px,pz):
    result=np.zeros_like(px)
    # Long structural bands have bounded additive weights; no multiplicative feedback.
    for frequency,weight in [(1.,.80),(2.07,.15),(4.31,.04),(9.17,.01)]:
        signal=np.maximum(1-abs(gradient_noise(px*frequency+frequency*3.7,pz*frequency-frequency*5.9)),0)
        result+=signal*weight
    return result

warpx=x+fbm(x*.0015+4,z*.0015-2)*155
warpz=z+fbm(x*.0017-3,z*.0017+8)*140
ridge=ridged_multifractal(warpx/1100,warpz/1100)
base=14+fbm(warpx*.0021+6,warpz*.0017-3)*28
uplift=np.zeros_like(x)
# Broad overlapping uplift zones guide the hierarchy; the ridged field and streams form the actual crests.
for cx,cz,rx,rz,angle,strength in LANDFORM['uplift_zones']:
    a=np.radians(angle);dx=(warpx-cx)*np.cos(a)+(warpz-cz)*np.sin(a);dz=-(warpx-cx)*np.sin(a)+(warpz-cz)*np.cos(a)
    zone=np.exp(-.5*((dx/rx)**2+(dz/rz)**2))*strength
    uplift=np.maximum(uplift,zone)
height=base+uplift*(.14+.86*ridge**1.25)
# Curving stream corridors define an open glacial main valley and subordinate catchments.
valleys=LANDFORM['valleys']
for index,path in enumerate(valleys):
    path=np.asarray(path,dtype=float);arc=np.r_[0,np.cumsum(np.linalg.norm(np.diff(path[:,:2],axis=0),axis=1))]
    samples=np.linspace(0,arc[-1],max(3,int(arc[-1]/35)))
    cx=CubicSpline(arc,path[:,0],bc_type="natural")(samples);cz=CubicSpline(arc,path[:,1],bc_type="natural")(samples)
    floors=PchipInterpolator(arc,path[:,2])(samples)
    points=np.stack([cx,cz,floors],axis=-1)
    for a,b in zip(points,points[1:]):
        d=b[:2]-a[:2];t=np.clip(((x-a[0])*d[0]+(z-a[1])*d[1])/np.dot(d,d),0,1)
        px=a[0]+d[0]*t;pz=a[1]+d[1]*t;distance=np.hypot(x-px,z-pz);floor=a[2]+(b[2]-a[2])*t
        width=72-np.clip((floor+27)/400,0,1)*30 if index==0 else 21-np.clip((floor-20)/400,0,1)*9
        transverse=np.maximum(distance-width,0)
        if index==0:
            relief=75+200*smooth(450,1350,-pz)
            profile=floor+(transverse/120)**1.5*relief
        else:
            profile=floor+transverse*1.12+transverse**1.55*.018
        mouth=1-smooth(210 if index else 310,300 if index else 440,distance)
        height-=np.maximum(height-profile,0)*mouth
old=np.load(OUT/"authored_site_source.npz")
original=RegularGridInterpolator((old["zs"],old["xs"]),old["height"])(np.stack([z.ravel(),x.ravel()],axis=-1)).reshape(x.shape)

source_wet=(old["height"]<=-29)&(abs(np.meshgrid(old["xs"],old["zs"])[0])<=95)&(np.meshgrid(old["xs"],old["zs"])[1]>=-435)&(np.meshgrid(old["xs"],old["zs"])[1]<=-40)
source_lake_lock=source_wet.copy()
wet_cells=source_wet[:-1,:-1]|source_wet[1:,:-1]|source_wet[:-1,1:]|source_wet[1:,1:]
source_lake_lock[:-1,:-1]|=wet_cells;source_lake_lock[1:,:-1]|=wet_cells
source_lake_lock[:-1,1:]|=wet_cells;source_lake_lock[1:,1:]|=wet_cells
lake_protection=RegularGridInterpolator((old["zs"],old["xs"]),source_lake_lock.astype(float),method="nearest",bounds_error=False,fill_value=0)
def shore_protection(px,pz):
    return lake_protection(np.stack([pz.ravel(),px.ravel()],axis=-1)).reshape(px.shape)>.5

def preserve_masks(px,pz):
    locked=np.hypot(px,pz)<=115
    path=np.array(SPEC["trail_points"],dtype=float)
    for a,b in zip(path,path[1:]):
        d=b-a;t=np.clip(((px-a[0])*d[0]+(pz-a[1])*d[1])/np.dot(d,d),0,1)
        locked|=np.hypot(px-a[0]-d[0]*t,pz-a[1]-d[1]*t)<=30
    for cx,cz,rx,rz,yaw in LANDFORM['preserved_rock_footprints']:
        angle=np.radians(yaw);dx=(px-cx)*np.cos(angle)+(pz-cz)*np.sin(angle);dz=-(px-cx)*np.sin(angle)+(pz-cz)*np.cos(angle)
        locked|=np.hypot(dx/rx,dz/rz)<=1.5
    lake=shore_protection(px,pz)
    return locked,lake
def preserve_mask(px,pz):
    site,lake=preserve_masks(px,pz)
    return site|lake
site_locked,lake_locked=preserve_masks(x,z)
locked=site_locked|lake_locked
site_distance=distance_transform_edt(~site_locked)*step;lake_distance=distance_transform_edt(~lake_locked)*step
mask=np.minimum(smooth(0,85,site_distance),smooth(0,25,lake_distance))
height=original*(1-mask)+height*mask
sinks=locked.copy()
iterations=int(LANDFORM["erosion_iterations"])
critical=44.+3.*np.clip(fbm(x/800+8,z/800-5)*.5+.5,0,1)
for cx,cz,rx,rz,yaw in LANDFORM['hard_rock_belts']:
    a=np.radians(yaw);dx=(x-cx)*np.cos(a)+(z-cz)*np.sin(a);dz=-(x-cx)*np.sin(a)+(z-cz)*np.cos(a)
    hard=(1-smooth(.65,1.05,np.hypot(dx/rx,dz/rz)))*smooth(280,420,height)
    critical=critical*(1-hard)+65*hard
uncut=height.copy()
height,breach_diagnostics=breach_depressions(
    height,step,(mask>.99).astype(float),sinks,maximum_cut=LANDFORM["breach_max_cut_m"])
core=uncut-height>.25
if core.any():
    channel_distance,nearest=distance_transform_edt(~core,sampling=(step,step),return_indices=True)
    profile=height[nearest[0],nearest[1]]+channel_distance*1.45
    height-=np.maximum(height-profile,0)*(channel_distance<80)*mask
height,sediment,simulation_drain,diagnostics=erode_bedrock(
    height,step,mask,sinks,iterations=iterations,rock_slope_degrees=critical)
print("Erosion, largest locked height change:",
      diagnostics["maximum_locked_height_change_m"],
      "drainage breach cut:",breach_diagnostics["cut_cap_m"])

xs,zs=old["xs"],old["zs"];xx,zz=np.meshgrid(xs,zs);query=np.stack([zz.ravel(),xx.ravel()],axis=-1)
h=RegularGridInterpolator((axis,axis),height)(query).reshape(xx.shape)
# Preserve authored terrain exactly on the final nonuniform mesh grid.
locked_final=preserve_mask(xx,zz)
# This mask is exact in the protected union; coarse-grid blending already handles its collar.
h[locked_final]=old["height"][locked_final]
original_dry=(old["height"]>-29)&(abs(xx)<=100)&(zz>=-440)&(zz<=-36)&~locked_final
h[original_dry]=np.maximum(h[original_dry],-27.8)

# Work on the existing mesh grid after the regional erosion simulation.
old_xs,old_zs=xs,zs
inner=h.copy()
x,z=np.meshgrid(old_xs,old_zs)
locked=abs(inner-old["height"])<1e-8

def fold(px,pz,cx,cz,rx,rz,angle):
    a=np.radians(angle);u=((px-cx)*np.cos(a)+(pz-cz)*np.sin(a))/rx;v=(-(px-cx)*np.sin(a)+(pz-cz)*np.cos(a))/rz
    d=np.hypot(u,v)
    return np.exp(-.5*d*d)*(1-smooth(2.1,2.8,d))

def feature_profile(px,pz,points,amplitudes,width):
    points=np.asarray(points,dtype=float)
    closest=np.full_like(px,np.inf);weight=np.zeros_like(px)
    for i,(a,b) in enumerate(zip(points,points[1:])):
        d=b-a;t=np.clip(((px-a[0])*d[0]+(pz-a[1])*d[1])/np.dot(d,d),0,1)
        distance=np.hypot(px-a[0]-d[0]*t,pz-a[1]-d[1]*t)
        nearer=distance<closest
        closest=np.where(nearer,distance,closest)
        weight=np.where(nearer,amplitudes[i]+(amplitudes[i+1]-amplitudes[i])*t,weight)
    return weight*np.exp(-.5*(closest/width)**2)*(1-smooth(2.1*width,2.8*width,closest))

# Fold the existing summit and the intervening spur, rather than stacking equally high crests.
shoulder=fold(x,z,-229,-1551,147,137,-18)
sample=RegularGridInterpolator((old_zs,old_xs),inner)
warp_x=x+shoulder*(43+.16*(z+1550))
warp_z=z+shoulder*(27-.23*(x+229))
warped=sample(np.stack([np.clip(warp_z,-extent,extent),np.clip(warp_x,-extent,extent)],axis=-1))
spur=feature_profile(x,z,[(-320,-1582),(-352,-1531),(-373,-1457),(-362,-1370)],[3,31,24,0],42)
gully=feature_profile(x,z,[(-234,-1568),(-218,-1492),(-185,-1425),(-161,-1330)],[.25,1.,.75,0],34)
delta=warped-inner+spur-16*gully
# Broaden the two terminal saddles identified by native camera rays before rebuilding the collar.
delta-=46*fold(x,z,-36,-1788,83,126,11)
delta-=55*fold(x,z,286,-1795,97,131,-16)
# Secondary branch profiles follow the existing fall line and terminate on the apron.
# Alternating eroded cirques and overlapping asymmetric spurs change slope at 80–220 m
# scales; the fluvial solver still provides the narrow first-order channels.
landforms=LANDFORM['secondary_profiles']
for points,amplitudes,width in landforms:
    delta+=feature_profile(x,z,points,amplitudes,width)

# Broad excavation at the two previously extruded edge saddles. This changes the
# inner landform, rather than hiding an edge behind a veil.
delta-=22*fold(x,z,-38,-1768,63,96,13)
delta-=18*fold(x,z,291,-1767,86,103,-12)
delta-=30*fold(x,z,7,1559,53,70,18)
delta[locked]=0
inner+=delta
# Ease the old west bank outside the physical lookout, rock and understory footprints.
# Leave the water basin and the exact authored site elsewhere untouched.
z_bank=np.array([-56.,-34.,-9.,12.])
source_bank=RegularGridInterpolator((old_zs,old_xs),inner)
bank_x,bank_z=np.meshgrid(old_xs,z_bank)
bank_heights=source_bank(np.stack([bank_z,bank_x],axis=-1))
low=bank_heights[0];high=bank_heights[-1]
bank_heights[1]=low+(high-low)*.25
bank_heights[2]=low+(high-low)*.74
profile=PchipInterpolator(z_bank,bank_heights,axis=0)(np.clip(old_zs,-56,12))
bank=(smooth(66,84,-x)*(1-smooth(141,162,-x)))*smooth(-56,-43,z)*(1-smooth(-4,12,z))
# Minimal waviness redirects the old perfectly straight bank line on its dry side.
profile+=1.1*np.sin((x+103)/13)*np.exp(-.5*((z+25)/12)**2)
bank_change=(profile-inner)*bank*.91
inner+=bank_change
outer_extent=LANDFORM["outer_half_extent_m"]
outer_step=LANDFORM["outer_grid_step_m"]
extension_left=np.arange(-outer_extent,-extent,outer_step)
extension_right=np.arange(extent+outer_step,outer_extent+.1,outer_step)
xs=np.r_[extension_left,old_xs,extension_right]
zs=np.r_[extension_left,old_zs,extension_right]
xx,zz=np.meshgrid(xs,zs);cx=np.clip(xx,-extent,extent);cz=np.clip(zz,-extent,extent);dx=xx-cx;dz=zz-cz;distance=np.hypot(dx,dz)
query=np.stack([cz.ravel(),cx.ravel()],axis=-1)
gz,gx=np.gradient(inner,old_zs,old_xs)
def at_edge(field):
    return RegularGridInterpolator((old_zs,old_xs),field)(query).reshape(xx.shape)
edge=at_edge(inner)
edge_slope=np.divide(at_edge(gx)*dx+at_edge(gz)*dz,distance,out=np.zeros_like(edge),where=distance>0)
# Continue each section at a bounded grade and release it gradually into the backing hills.
# A 24 m first cell can gain at most 5.3 m, compared with 100 m in the previous extrapolation.
initial=edge+np.clip(edge_slope,-.44,.22)*distance*np.exp(-distance/210)
warp_x=xx+fbm(xx*.0015+4,zz*.0015-2)*155;warp_z=zz+fbm(xx*.0017-3,zz*.0017+8)*140
ridge=ridged_multifractal(warp_x/1280,warp_z/1280)
back=np.zeros_like(xx)
for px,pz,rx,rz,yaw,amount in LANDFORM['backing_ranges']:
    back=np.maximum(back,amount*fold(warp_x,warp_z,px,pz,rx,rz,yaw))
outer=50+back*(.38+.62*ridge)
blend=smooth(20,700,distance)
height=initial*(1-blend)+outer*blend
inside=(distance==0);height[inside]=edge[inside]
gully_full=np.where(inside,at_edge(gully),0)

h=height
x,z=xx,zz
gz,gx=np.gradient(h,zs,xs)
slope=np.hypot(gx,gz)
meadow=(1-smooth(.55,1.1,slope))*(1-smooth(250,410,h))*(.74+.26*np.clip(.5+fbm(x/80+3,z/80-8),0,1))
line=265+55*fbm(x/700+12,z/700-3)
forest=meadow*smooth(-24,-9,h)*(1-smooth(line-65,line+35,h))
patch=np.clip(.5+fbm(x/160+15,z/160-8),0,1)
forest*=1-smooth(.30,.66,patch)
forest*=smooth(21,42,np.hypot(x,z))
track=np.zeros_like(h)
drain=RegularGridInterpolator((axis,axis),simulation_drain,bounds_error=False,fill_value=0.0)(np.stack([z.ravel(),x.ravel()],axis=-1)).reshape(h.shape)
old_q=np.stack([z.ravel(),x.ravel()],axis=-1)
def old_aligned(name):
    return RegularGridInterpolator((old["zs"],old["xs"]),old[name],bounds_error=False,fill_value=np.nan)(old_q).reshape(h.shape)
locked=abs(h-old_aligned("height"))<1e-8
for field,name in [(meadow,"meadow"),(forest,"forest"),(track,"trail"),(drain,"drain")]:field[locked]=old_aligned(name)[locked]
forest*=1-track
forest[locked]=old_aligned("forest")[locked]
drain=np.maximum(drain,gully_full*.6)
drain[locked]=old_aligned("drain")[locked]

points=np.stack([xx,height,zz],axis=-1).reshape(-1,3);rows,cols=xx.shape;ids=np.arange(rows*cols).reshape(rows,cols)
a=ids[:-1,:-1].ravel();b=ids[:-1,1:].ravel();c=ids[1:,1:].ravel();d=ids[1:,:-1].ravel();faces=np.vstack([np.stack([a,d,b],axis=-1),np.stack([b,d,c],axis=-1)])
normals=np.zeros_like(points);tri=points[faces];nf=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0])
for i in range(3):np.add.at(normals,faces[:,i],nf)
normals/=np.maximum(np.linalg.norm(normals,axis=1,keepdims=True),1e-9)
colors=np.stack([meadow,track,drain,forest],axis=-1).reshape(-1,4)
mesh_path=OUT.parent/"lookout_terrain.obj"
mesh_temp=mesh_path.with_suffix(".obj.tmp")
with mesh_temp.open("w",encoding="utf-8",newline="\n") as stream:
    stream.write("o WestRidgeTerrain\ns 1\n")
    for point,color in zip(points,colors):
        stream.write("v %.4f %.4f %.4f %.4f %.4f %.4f %.4f\n"%tuple(np.r_[point,color]))
    for normal in normals:stream.write("vn %.5f %.5f %.5f\n"%tuple(normal))
    for face in faces+1:stream.write("f "+" ".join(f"{i}//{i}" for i in face)+"\n")
mesh_temp.replace(mesh_path)
field_path=OUT/"terrain_field.npz"
field_temp=field_path.with_suffix(".tmp.npz")
np.savez_compressed(field_temp,xs=xs,zs=zs,height=h,meadow=meadow,
                    forest=forest,trail=track,drain=drain)
field_temp.replace(field_path)
print("Saved terrain",len(points),"vertices",len(faces),"triangles")
