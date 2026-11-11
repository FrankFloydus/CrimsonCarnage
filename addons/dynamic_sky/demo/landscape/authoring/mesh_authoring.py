# Small offline geometry helpers for the authored meadow, ferns and trail details.
# They are independent of the demonstration spruce generators.
from pathlib import Path
import math
import numpy as np
from PIL import Image

UP=np.array((0.,1.,0.))
tau=2*math.pi


def unit(v):
    return v/max(np.linalg.norm(v),.00001)


def axes(tangent):
    ref=UP if abs(tangent[1])<.9 else np.array((1.,0.,0.))
    n=unit(np.cross(tangent,ref))
    return n,np.cross(tangent,n)


def source_palette(image_path):
    art=np.asarray(Image.open(image_path).convert("RGBA"))
    eligible=(art[:,:,3]>240)&(art[:,:,1]>art[:,:,0]*1.07)&(art[:,:,1]>art[:,:,2]*1.06)
    rows,columns=np.where(eligible)
    return [((x+.5)/art.shape[1],1-(y+.5)/art.shape[0])
            for x,y in zip(columns[::83],rows[::83])]


def write_text_atomic(target,content):
    target=Path(target)
    temporary=target.with_suffix(target.suffix+".tmp")
    temporary.write_text(content,encoding="utf-8")
    temporary.replace(target)


class Mesh:
    def __init__(self, output_directory, random_source, palette):
        self.output_directory=Path(output_directory)
        self.random_source=random_source
        self.palette=palette
        self.verts=[]
        self.uvs=[]
        self.faces=[]
    def add(self,pos,uv):
        self.verts.append(pos)
        self.uvs.append(uv)
        return len(self.verts)
    def quad(self,a,b,c,d):
        self.faces.extend([(a,b,c),(a,c,d)])
    def tube(self,points,radii,sides,variation=.07):
        rings=[]
        length=0.0
        for i,p in enumerate(points):
            direction=unit(points[min(i+1,len(points)-1)]-points[max(i-1,0)])
            normal,binormal=axes(direction)
            if i>0:
                length+=np.linalg.norm(points[i]-points[i-1])
            ring=[]
            wobble=self.random_source.uniform(1-variation,1+variation,sides)
            for j in range(sides+1):
                a=tau*j/sides
                arm=normal*math.cos(a)+binormal*math.sin(a)
                pt=p+arm*radii[i]*wobble[j%sides]
                ring.append(self.add(pt,(1.23+j/sides*.55,length*.67)))
            rings.append(ring)
        for low,high in zip(rings,rings[1:]):
            for j in range(sides):
                self.quad(low[j],low[j+1],high[j+1],high[j])
    def tuft(self,root,tip,width):
        axis=unit(tip-root)
        n,b=axes(axis)
        midpoint=root+(tip-root)*.54
        u,v=self.palette[self.random_source.integers(len(self.palette))]
        base=self.add(root,(u,v))
        end=self.add(tip,(u+.003,v+.008))
        ring=[]
        for i in range(4):
            angle=tau*i/4+.35
            pos=midpoint+(n*math.cos(angle)+b*math.sin(angle)*.63)*width*self.random_source.uniform(.84,1.14)
            ring.append(self.add(pos,(u+.003*i,v+.003)))
        for i in range(4):
            a=ring[i]
            b=ring[(i+1)%4]
            self.faces.extend([(base,b,a),(a,b,end)])
    def save(self,file_name):
        target=self.output_directory/file_name
        temp=target.with_suffix(".obj.tmp")
        with temp.open("w",encoding="ascii") as f:
            f.write("o RidgeSpruce\ns 1\n")
            for x,y,z in self.verts:
                f.write(f"v {x:.5f} {y:.5f} {z:.5f}\n")
            for u,v in self.uvs:
                f.write(f"vt {u:.5f} {v:.5f}\n")
            for a,b,c in self.faces:
                f.write(f"f {a}/{a} {b}/{b} {c}/{c}\n")
        temp.replace(target)
        print(file_name,len(self.verts),"vertices",len(self.faces),"triangles")
