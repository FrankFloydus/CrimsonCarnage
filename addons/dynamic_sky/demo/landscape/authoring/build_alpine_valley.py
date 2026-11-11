from pathlib import Path
import json
import time
import numpy as np
from scipy.ndimage import gaussian_filter
from scipy.interpolate import RegularGridInterpolator

OUT=Path(__file__).resolve().parent
LANDSCAPE=OUT.parent
SPEC=json.loads((OUT/"site_spec.json").read_text(encoding="utf-8-sig"))

SEED=SPEC["terrain_seed"]
started=time.perf_counter()

def smooth(a,b,x):
    t=np.clip((x-a)/(b-a),0.,1.)
    return t*t*(3-2*t)

def hash2(x,z):
    v=np.sin(x*127.1+z*311.7+SEED*.00013)*43758.5453
    return v-np.floor(v)

def noise(x,z):
    ix,iz=np.floor(x),np.floor(z)
    tx,tz=x-ix,z-iz
    tx,tz=tx*tx*(3-2*tx),tz*tz*(3-2*tz)
    a=hash2(ix,iz)*(1-tx)+hash2(ix+1,iz)*tx
    b=hash2(ix,iz+1)*(1-tx)+hash2(ix+1,iz+1)*tx
    return a*(1-tz)+b*tz

def fbm(x,z):
    result=np.zeros(np.broadcast(x,z).shape)
    for scale,weight in [(1,.56),(2.07,.25),(4.31,.13),(9.17,.06)]:
        result+=noise(x*scale+scale*5.1,z*scale-scale*2.7)*weight
    return result

basin=np.load(OUT/"lake_basin_source.npz")
original=RegularGridInterpolator((basin["zs"],basin["xs"]),basin["height"],bounds_error=False,fill_value=-40)

step=float(SPEC["erosion_grid_step_meters"])
extent=float(SPEC["domain_half_extent_meters"])
axis=np.arange(-extent,extent+.1,step)
x,z=np.meshgrid(axis,axis)
radius=np.hypot(x,z)
warp_x=x+(fbm(x*.0018,z*.0018)-.5)*210
warp_z=z+(fbm(x*.0017+9,z*.0017-4)-.5)*190
geo_x=(warp_x*.86+warp_z*.39)*.0023
geo_z=(warp_z*.89-warp_x*.23)*.0023
ridge=1-np.abs(noise(geo_x,geo_z)*2-1)
small_ridge=1-np.abs(noise(geo_x*2.13+4.2,geo_z*2.13-5.1)*2-1)
regional=fbm(warp_x*.0011+5.8,warp_z*.0011-8.4)
envelope=smooth(45,1300,radius)**.90
base=-38*smooth(12,205,-z)+np.maximum(z,0)*.015
height=base+envelope*(120+430*ridge**1.55+180*small_ridge**1.8+115*regional)
height+=(fbm(warp_x*.013,warp_z*.013)-.5)*19*envelope
axis_x=24*np.sin((z+100)/280)+.024*(-z)
across=np.abs(x-axis_x)
floor=-43+smooth(400,1350,-z)*245
profile=floor+(np.maximum(across-38,0)/175)**1.65*235
profile+=(fbm(x*.018,z*.018)-.5)*28*smooth(55,210,across)
valley=smooth(-10,100,-z)*(1-smooth(1250,1630,-z))
height=height*(1-valley)+np.minimum(height,profile)*valley

# Long asymmetric fault ridges establish a different mass and face in each direction.
faults=SPEC["fault_ridges"]
fault_field=np.full_like(height,-1000.)
for fault_index,path in enumerate(faults):
    path=np.asarray(path,dtype=float)
    for a,b in zip(path,path[1:]):
        direction=b[:2]-a[:2]
        t=np.clip(((x-a[0])*direction[0]+(z-a[1])*direction[1])/np.dot(direction,direction),0,1)
        nearest_x=a[0]+direction[0]*t;nearest_z=a[1]+direction[1]*t
        distance=np.hypot(x-nearest_x,z-nearest_z)
        side=direction[0]*(z-nearest_z)-direction[1]*(x-nearest_x)
        warp=(noise(x*.014+fault_index*3,z*.014)-.5)*25
        distance=np.maximum(distance+warp,0)
        crest=a[2]+(b[2]-a[2])*t+(noise(nearest_x*.018,nearest_z*.018)-.5)*34
        cliff_slope=np.where(side>0,2.05,1.25)
        drop=np.minimum(distance,25)*.42
        drop+=np.clip(distance-25,0,80)*cliff_slope
        drop+=np.maximum(distance-105,0)*.78
        ridge_height=crest-drop
        fault_field=np.maximum(fault_field,ridge_height)
structure=smooth(210,480,radius)
height=height*(1-structure)+np.maximum(height*.67,fault_field)*structure
height+=(fbm(x*.028+8,z*.028-5)-.5)*11*structure

# Downhill water accumulation creates connected incised channels.
neighbors=[(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(-1,1),(1,-1),(1,1)]
drainage=np.zeros_like(height)
for erosion_pass in range(3):
    candidates=np.stack([np.roll(height,(dz,dx),(0,1)) for dz,dx in neighbors])
    downhill=np.argmin(candidates,axis=0)
    lowest=np.min(candidates,axis=0)
    row,col=np.indices(height.shape)
    destination=np.empty(height.size,dtype=np.int64)
    flat_index=np.arange(height.size).reshape(height.shape)
    for i,(dz,dx) in enumerate(neighbors):
        shifted=np.roll(flat_index,(dz,dx),(0,1))
        destination[downhill.ravel()==i]=shifted.ravel()[downhill.ravel()==i]
    valid=lowest.ravel()<height.ravel()
    water=np.ones(height.size)
    for cell in np.argsort(height.ravel())[::-1]:
        if valid[cell]:
            water[destination[cell]]+=water[cell]
    flow=np.log1p(water.reshape(height.shape))
    gradient_z,gradient_x=np.gradient(height,step)
    slope=np.hypot(gradient_x,gradient_z)
    channel=gaussian_filter(flow,.72)*smooth(.10,.68,slope)
    height-=np.minimum(channel*(1.5 if erosion_pass==0 else .65),12)
    drainage=np.maximum(drainage,smooth(3.6,7.6,flow))
    print("erosion",erosion_pass,time.perf_counter()-started)

# Talus relaxes unstable slopes into scree aprons.
for iteration in range(32):
    delta=np.zeros_like(height)
    for dz,dx in neighbors[:4]:
        neighbor=np.roll(height,(dz,dx),(0,1))
        transport=np.maximum(height-neighbor-step*.93,0)*.075
        delta-=transport
        delta+=np.roll(transport,(-dz,-dx),(0,1))
    height+=delta

height=gaussian_filter(height,.65)

# Retain the authored basin and its nearby waterline, blending above the bank.
old_surface=original(np.stack([z.ravel(),x.ravel()],axis=-1)).reshape(x.shape)
basin_rect=(1-smooth(105,145,np.abs(x)))*smooth(-490,-445,z)*(1-smooth(-38,-18,z))
basin_weight=basin_rect*(1-smooth(-19,22,old_surface))
height=height*(1-basin_weight)+old_surface*basin_weight
# A dry irregular collar closes the lake entirely inside its authored water plane.
lake_center=9*np.sin((z+235)*.009)
lake_radius=np.sqrt(((x-lake_center)/69)**2+((z+235)/182)**2)
lake_radius+=(noise(x*.035,z*.035)-.5)*.055
bank=-29+(lake_radius-1)*28+(noise(x*.13,z*.13)-.5)*.38
height=np.maximum(height,bank*basin_rect+height*(1-basin_rect))
# The station rests on a gently warped rocky spur, rather than a cut vertical plateau.
pad_x=x+1.8
pad_z=z-.2
pad_edge=np.maximum(np.abs(pad_x)-15.8,np.abs(pad_z)-10.6)
pad_edge+=(noise(x*.12,z*.12)-.5)*1.8*smooth(0,8,pad_edge)
pad=1-smooth(-.1,24,pad_edge)
pad_floor=-.058+(noise(x*.23,z*.21)-.5)*.045
height=height*(1-pad)+pad_floor*pad

# A winding footpath connects the clearing to the lower rear slope.
path=np.array(SPEC["trail_points"],dtype=float)
trail=np.zeros_like(height)
trail_distance=np.full_like(height,10000.)
sample_height=RegularGridInterpolator((axis,axis),height)
for a,b in zip(path,path[1:]):
    direction=b-a
    t=np.clip(((x-a[0])*direction[0]+(z-a[1])*direction[1])/np.dot(direction,direction),0,1)
    px=a[0]+direction[0]*t;pz=a[1]+direction[1]*t
    distance=np.hypot(x-px,z-pz)
    trail_distance=np.minimum(trail_distance,distance)
    weight=1-smooth(.65,2.5+(noise(x*.4,z*.4)-.5)*.3,distance)
    ha=float(sample_height((a[1],a[0])));hb=float(sample_height((b[1],b[0])))
    height=height*(1-weight*.75)+(ha+(hb-ha)*t-.09)*weight*.75
    trail=np.maximum(trail,weight)

# Sample a nonuniform editable grid, with more geometry near the station and lake.
xs=np.unique(np.round(np.r_[np.arange(-extent,extent+.1,12),np.arange(-360,360.1,4),np.arange(-36,36.1,1.5)],4))
zs=np.unique(np.round(np.r_[np.arange(-extent,extent+.1,12),np.arange(-600,240.1,4),np.arange(-35,25.1,1)],4))
xx,zz=np.meshgrid(xs,zs)
query=np.stack([zz.ravel(),xx.ravel()],axis=-1)
h=RegularGridInterpolator((axis,axis),height)(query).reshape(xx.shape)
drain=RegularGridInterpolator((axis,axis),drainage)(query).reshape(xx.shape)
track=RegularGridInterpolator((axis,axis),trail)(query).reshape(xx.shape)
gz,gx=np.gradient(h,zs,xs)
slope=np.hypot(gx,gz)
meadow=(1-smooth(.55,1.1,slope))*(1-smooth(180,310,h))
meadow*=.60+.40*noise(xx*.016+3.2,zz*.016-9.7)
forest=meadow*smooth(-24,-9,h)*(1-smooth(150,250,h))*(1-smooth(.30,.72,noise(xx*.009+15,zz*.009-8)))
forest*=smooth(21,42,np.hypot(xx,zz))*(1-track)
path_distance=RegularGridInterpolator((axis,axis),trail_distance)(query).reshape(xx.shape)
forest*=smooth(6.0,11.0,path_distance)
forest*=.45+.55*smooth(80,210,np.hypot(xx,zz))
for cx,cz,rx,rz,yaw in [(32,43,9.4,6.1,17),(8,66,12.8,8.3,-29),(39,132,21.5,13.2,22),(-14,87,9.4,9.9,-19)]:
    angle=np.radians(yaw)
    dx=(xx-cx)*np.cos(angle)+(zz-cz)*np.sin(angle)
    dz=-(xx-cx)*np.sin(angle)+(zz-cz)*np.cos(angle)
    forest*=smooth(1.0,1.35,np.hypot(dx/rx,dz/rz))
colors=np.stack([meadow,track,drain,forest],axis=-1).reshape(-1,4)
v=np.stack([xx,h,zz],axis=-1).reshape(-1,3)
rows,cols=xx.shape
ids=np.arange(rows*cols).reshape(rows,cols)
a=ids[:-1,:-1].ravel();b=ids[:-1,1:].ravel();c=ids[1:,1:].ravel();d=ids[1:,:-1].ravel()
faces=np.vstack([np.stack([a,d,b],axis=-1),np.stack([b,d,c],axis=-1)])
normals=np.zeros_like(v)
tri=v[faces];nf=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0])
for corner in range(3):np.add.at(normals,faces[:,corner],nf)
normals/=np.maximum(np.linalg.norm(normals,axis=1,keepdims=True),1e-9)
with (LANDSCAPE/"lookout_terrain.obj.tmp").open("w") as f:
    f.write("o AlpineValley\ns 1\n")
    for p,color in zip(v,colors):f.write("v %.4f %.4f %.4f %.4f %.4f %.4f %.4f\n"%tuple(np.r_[p,color]))
    for n in normals:f.write("vn %.5f %.5f %.5f\n"%tuple(n))
    for face in faces+1:f.write("f "+" ".join(f"{i}//{i}" for i in face)+"\n")
(LANDSCAPE/"lookout_terrain.obj.tmp").replace(LANDSCAPE/"lookout_terrain.obj")
np.savez_compressed(OUT/"terrain_field.npz",xs=xs,zs=zs,height=h,meadow=meadow,trail=track,drain=drain,forest=forest)
print("vertices",len(v),"triangles",len(faces),"range",h.min(),h.max(),"seconds",time.perf_counter()-started)





