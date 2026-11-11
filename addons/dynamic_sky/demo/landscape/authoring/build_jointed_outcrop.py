from pathlib import Path
import numpy as np
from scipy.spatial import HalfspaceIntersection

OUT=Path(__file__).resolve().parent.parent/"details"
def unit(x):
    return x/max(np.linalg.norm(x),1e-12)
planes=[
    ((1,.12,.15),.63),((-1,.18,-.11),.57),
    ((.16,1,-.10),.46),((-.28,1,.16),.50),((.05,1,.38),.51),
    ((.08,-1,.02),.48),((.18,.12,1),.54),((-.28,.18,-1),.56),
    ((.85,.42,.65),.68),((-.68,.58,.50),.65),
    ((.57,-.45,-.72),.68),((-.62,-.32,-.80),.65),
    ((.80,.44,-.65),.65),((-.75,.18,-.70),.67),
]
normals=np.array([unit(np.array(n,dtype=float)) for n,d in planes])
distances=np.array([d for n,d in planes])
original_corners=HalfspaceIntersection(np.column_stack([normals,-distances]),np.zeros(3)).intersections
# Narrow secondary joint cuts weather the original corners while retaining broad planes.
bevel_normals=[];bevel_distances=[]
for first in range(len(normals)):
    for second in range(first+1,len(normals)):
        edge=original_corners[(abs(original_corners@normals[first]-distances[first])<1e-6)&
                              (abs(original_corners@normals[second]-distances[second])<1e-6)]
        if len(edge)!=2 or normals[first]@normals[second]>.92:continue
        normal=unit(normals[first]+normals[second])
        width=.008+.012*(.5+.5*np.sin(first*19.7+second*7.3))
        bevel_normals.append(normal)
        bevel_distances.append(np.max(original_corners@normal)-width)
normals=np.concatenate([normals,np.array(bevel_normals)])
distances=np.concatenate([distances,np.array(bevel_distances)])
corners=HalfspaceIntersection(np.column_stack([normals,-distances]),np.zeros(3)).intersections
verts=[];uvs=[];faces=[]
for block,scale,translation,yaw in [
    (0,np.array([1.,1.,1.]),np.zeros(3),0),
    (1,np.array([.54,.47,.71]),np.array([.45,-.32,.25]),-.25),
    (2,np.array([.47,.66,.66]),np.array([-.52,.03,-.20]),.28),
]:
    c,s=np.cos(yaw),np.sin(yaw)
    rotation=np.array([[c,0,s],[0,1,0],[-s,0,c]])
    for face_id,(normal,distance) in enumerate(zip(normals,distances)):
        polygon=corners[np.abs(corners@normal-distance)<1e-6]
        if len(polygon)<3:continue
        center=polygon.mean(0)
        u=unit(np.cross(normal,np.array([0,1,0]) if abs(normal[1])<.9 else np.array([1,0,0])))
        v=np.cross(normal,u)
        angles=np.arctan2((polygon-center)@v,(polygon-center)@u)
        polygon=polygon[np.argsort(angles)]
        edge_directions=np.roll(polygon,-1,axis=0)-polygon
        edge_lengths=np.linalg.norm(edge_directions,axis=1)
        cache={}
        def add(point):
            key=tuple(np.round(point,9))
            if key in cache:return cache[key]
            offsets=point-polygon
            inside=np.einsum("ij,j->i",np.cross(edge_directions,offsets),normal)/edge_lengths
            margin=max(float(inside.min()),0)
            weather=min(margin/.045,1)
            rough=(np.sin(point@np.array([37.1,23.7,41.9]))*.003+
                   np.sin(point@np.array([73.3,-31.1,59.4]))*.0015)*weather
            p=point+normal*rough
            p+=np.array([np.sin(point@np.array([9.,3.,-7.])),np.sin(point@np.array([5.,-11.,8.])),np.sin(point@np.array([-6.,7.,13.]))])*.0025
            p=rotation@(p*scale)+translation
            for level in [-.25,.035,.27]:
                joint=abs(p[1]-level-p[0]*.19+p[2]*.13)
                groove=max(0,1-joint/.018)
                p[[0,2]]*=1-groove*.035
            cache[key]=len(verts);verts.append(p)
            uvs.append(((point-center)@u,(point-center)@v))
            return cache[key]
        def triangle(a,b,c,level):
            if level:
                ab=(a+b)*.5;bc=(b+c)*.5;ca=(c+a)*.5
                triangle(a,ab,ca,level-1);triangle(ab,b,bc,level-1)
                triangle(ca,bc,c,level-1);triangle(ab,bc,ca,level-1)
            else:faces.append((add(a),add(b),add(c)))
        for edge in range(len(polygon)):
            triangle(center,polygon[edge],polygon[(edge+1)%len(polygon)],2)
points=np.asarray(verts);idx=np.asarray(faces)
low,high=points.min(0),points.max(0)
# Retain an authored unit envelope, with a buried foot and offset, unequal shoulders.
extent=np.array([1.4,1.08,1.16])
points=(points-(low+high)*.5)/(high-low)*extent
tri=points[idx];fn=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0])
vn=np.zeros_like(points)
for corner in range(3):np.add.at(vn,idx[:,corner],fn)
vn/=np.maximum(np.linalg.norm(vn,axis=1,keepdims=True),1e-12)
with (OUT/"ridge_outcrop.obj.tmp").open("w") as mesh:
    mesh.write("o JointedGneissOutcrop\ns 1\n")
    for point in points:mesh.write("v %.6f %.6f %.6f\n"%tuple(point))
    for uv in uvs:mesh.write("vt %.6f %.6f\n"%tuple(uv))
    for normal in vn:mesh.write("vn %.6f %.6f %.6f\n"%tuple(normal))
    for face in idx+1:mesh.write("f "+" ".join(f"{i}/{i}/{i}" for i in face)+"\n")
(OUT/"ridge_outcrop.obj.tmp").replace(OUT/"ridge_outcrop.obj")
print("jointed outcrop",len(points),"vertices",len(faces),"triangles",low,high)


