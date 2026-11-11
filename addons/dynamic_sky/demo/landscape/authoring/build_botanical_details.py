from pathlib import Path
import numpy as np

from mesh_authoring import Mesh,unit,axes,source_palette

HERE=Path(__file__).resolve().parent
VEGETATION=HERE.parent/"vegetation"
DETAILS=HERE.parent/"details"
MATERIALS=HERE.parent.parent/"materials"
geometry_rng=np.random.default_rng(90472)
legacy_palette=source_palette(MATERIALS/"spruce_bough.png")
rng=np.random.default_rng(740119)
from PIL import Image
from scipy.ndimage import distance_transform_edt
image=np.asarray(Image.open(MATERIALS/"alpine_groundcover_atlas.png").convert("RGBA"))
height,width=image.shape[:2]
mask=(image[:,:,3]>245)&(image[:,:,1]>image[:,:,0]*1.01)&(image[:,:,1]>image[:,:,2]*1.02)
mask &= distance_transform_edt(image[:,:,3]>240)>6
mask[:height//2,:]=False
ys,xs=np.where(mask)
palette=np.stack([(xs+.5)/width,1-(ys+.5)/height],axis=-1)
mesh=Mesh(VEGETATION,geometry_rng,legacy_palette)
up=np.array([0.,1.,0.])
for frond in range(9):
    yaw=frond*2.399963+rng.uniform(-.2,.2)
    radial=np.array([np.cos(yaw),0,np.sin(yaw)])
    across=np.array([-np.sin(yaw),0,np.cos(yaw)])
    reach=rng.uniform(.63,.99);rise=rng.uniform(.36,.62)
    def point(t):
        return radial*reach*t+up*(np.sin(t*np.pi*.94)*rise+.045*t)
    stem=[point(t) for t in np.linspace(0,1,10)]
    mesh.tube(stem,np.linspace(.004,.0006,10),4)
    for level in range(16):
        t=.10+level*.052
        center=point(t)
        length=(.15*(1-t)**.70+.019)*rng.uniform(.83,1.10)
        broad=length*(.20+.03*np.sin(level))
        for side in [-1,1]:
            direction=unit(across*side+radial*(.23+.65*t)+up*rng.uniform(-.13,.23))
            offset,normal=axes(direction)
            uv=palette[rng.integers(len(palette))]
            base=center+across*side*.003
            hub=mesh.add(base+direction*length*.48+up*.002,uv)
            ring=[]
            contour=[]
            for edge in [-1,1]:
                positions=np.linspace(0,1,17)
                if edge==1:positions=positions[::-1]
                for along in positions:
                    outline=np.sin(along*np.pi)**.72
                    lobes=.40+.60*abs(np.sin(along*np.pi*7.5))
                    lateral=edge*broad*outline*lobes
                    location=base+direction*length*along+offset*lateral
                    location+=up*np.sin(along*np.pi)*.005
                    contour.append(mesh.add(location,(uv[0]+lateral*.03,uv[1]+along*.001)))
            for k in range(len(contour)):
                mesh.faces.append((hub,contour[k],contour[(k+1)%len(contour)]))
for i,uv in enumerate(mesh.uvs):
    if uv[0]>1.1:mesh.uvs[i]=palette[rng.integers(len(palette))]
mesh.save("alpine_fern.obj")

wood=Mesh(DETAILS,geometry_rng,legacy_palette)
trunk=[np.array([-.62,0,-.05]),np.array([-.24,.025,.018]),np.array([.15,.015,.01]),np.array([.58,.055,-.03])]
wood.tube(trunk,[.025,.031,.023,.012],8)
for origin,tip in [(np.array([-.14,.02,.01]),np.array([-.34,.085,.37])),(np.array([.22,.02,.01]),np.array([.47,.10,-.29])),(np.array([-.28,.015,0]),np.array([-.60,.045,-.24]))]:
    wood.tube([origin,(origin+tip)*.5,tip],[.012,.007,.002],5)
wood.save("fallen_branch.obj")

heads=Mesh(VEGETATION,geometry_rng,legacy_palette)
for i in range(7):
    yaw=rng.uniform(0,np.pi*2)
    radial=np.array([np.cos(yaw),0,np.sin(yaw)])
    h=rng.uniform(.55,.95)
    stem=[radial*.025,np.array([0,h*.48,0])+radial*.08,np.array([0,h*.78,0])+radial*.18,np.array([0,h,0])+radial*.26]
    heads.tube(stem,[.0017,.0015,.0012,.0006],4)
    for k in range(8):
        t=.62+k*.047
        center=radial*(.04+.24*t)+up*h*t
        for side in [-1,1]:
            across=np.array([-radial[2],0,radial[0]])*side
            tip=center+across*rng.uniform(.019,.046)+up*.018
            heads.tuft(center,tip,.0038)
heads.save("straw_seedheads.obj")



