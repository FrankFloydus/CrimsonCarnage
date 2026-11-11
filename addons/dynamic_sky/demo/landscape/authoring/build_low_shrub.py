from pathlib import Path
import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt

from mesh_authoring import Mesh,unit,axes,source_palette

HERE=Path(__file__).resolve().parent
VEGETATION=HERE.parent/"vegetation"
MATERIALS=HERE.parent.parent/"materials"
geometry_rng=np.random.default_rng(90472)
legacy_palette=source_palette(MATERIALS/"spruce_bough.png")
rng=np.random.default_rng(774913)
atlas=np.asarray(Image.open(MATERIALS/"alpine_groundcover_atlas.png").convert("RGBA"))
h,w=atlas.shape[:2]
eligible=(atlas[:,:,3]>240)&(atlas[:,:,1]>atlas[:,:,0]*1.015)&(atlas[:,:,1]>atlas[:,:,2]*1.01)
eligible &= distance_transform_edt(atlas[:,:,3]>240)>6
eligible[:h//2,:w//2]=False
ys,xs=np.where(eligible)
palette=np.stack([(xs+.5)/w,1-(ys+.5)/h],axis=-1)
mesh=Mesh(VEGETATION,geometry_rng,legacy_palette)
up=np.array([0.,1.,0.])
def leaf(center,direction,length,width):
    normal,binormal=axes(direction)
    axis=center+direction*length*.5
    uv=palette[rng.integers(len(palette))]
    hub=mesh.add(axis+normal*.0008,uv)
    ring=[]
    for i in range(8):
        theta=i*np.pi/4
        point=axis+direction*np.cos(theta)*length*.5+binormal*np.sin(theta)*width*.5
        ring.append(mesh.add(point,(uv[0]+np.sin(theta)*.001,uv[1]+np.cos(theta)*.001)))
    for i in range(8):mesh.faces.append((hub,ring[i],ring[(i+1)%8]))
for branch in range(10):
    angle=branch*2.399963+rng.uniform(-.22,.22)
    radial=np.array([np.cos(angle),0,np.sin(angle)])
    across=np.array([-np.sin(angle),0,np.cos(angle)])
    reach=rng.uniform(.27,.53)
    curve=[np.array([0,.008,0]),radial*reach*.36+up*.065,radial*reach*.72+up*rng.uniform(.12,.20),radial*reach+up*rng.uniform(.12,.24)]
    mesh.tube(curve,[.008,.005,.0028,.0008],5)
    for side_branch in range(6):
        t=.20+side_branch*.13
        root=curve[0]*(1-t)+curve[-1]*t
        root+=up*np.sin(t*np.pi)*.07
        side=1 if side_branch%2 else -1
        direction=unit(radial*.45+across*side+up*rng.uniform(.25,.55))
        twig_reach=reach*(.45-.24*t)
        tip=root+direction*twig_reach
        mesh.tube([root,(root+tip)*.5,tip],[.0024,.0015,.0004],4)
        for shoot in range(8):
            p=root+(tip-root)*(shoot+.4)/8
            for whorl in range(3):
                twist=whorl*2*np.pi/3+shoot*2.3999
                lateral,vertical=axes(direction)
                leaf_dir=unit(direction*.26+lateral*np.cos(twist)+vertical*np.sin(twist)*.7+up*.20)
                leaf(p,leaf_dir,rng.uniform(.015,.028),rng.uniform(.006,.012))
mesh.save("low_shrub.obj")
print("atlas eligible pixels",len(palette))

