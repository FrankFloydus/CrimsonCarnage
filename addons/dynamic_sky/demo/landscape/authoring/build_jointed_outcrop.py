# Original offline gneiss geometry for the saved West Ridge demo.
# Run with NumPy, SciPy, scikit-image 0.25.2 and PyMeshLab 2025.7.post1.
# The game loads only the baked OBJ files; these libraries are authoring tools.
import argparse
import json
from pathlib import Path

import numpy as np
import pymeshlab
from scipy.spatial import ConvexHull
from scipy.special import logsumexp
from skimage.measure import marching_cubes


ENVELOPE = np.array([1.4, 1.08, 1.16])


def smooth_max(a, b, radius):
    weight = np.maximum(radius - np.abs(a - b), 0.0) / radius
    return np.maximum(a, b) + weight * weight * radius * 0.25


LARGE_FORMS = [
    # Main upright mass, with a slanted exposed summit and a deep rear shoulder.
    [(-.58,-.52,-.45),(-.38,-.55,-.54),(.27,-.53,-.49),(.40,-.48,.24),
     (.11,-.53,.55),(-.57,-.45,.42),(-.69,-.08,-.29),(-.61,.14,-.43),
     (-.50,.29,-.42),(-.24,.49,-.30),(.01,.48,-.39),(.24,.36,-.40),
     (.37,.22,-.28),(.40,.17,.19),(.23,.43,.31),(-.18,.52,.20),
     (-.46,.31,.38),(-.62,.15,.24),(-.45,-.05,-.58),(.05,.17,-.53)],
    # Lower adjacent block; a blunt uneven toe, fully embedded at its base.
    [(-.17,-.53,-.49),(.41,-.55,-.60),(.67,-.48,-.32),(.64,-.50,.18),
     (.31,-.55,.43),(-.14,-.49,.22),(-.23,-.18,-.45),(-.04,.10,-.58),
     (.24,.19,-.53),(.43,.22,-.35),(.62,.05,-.29),(.58,.11,.10),
     (.39,.27,.16),(.15,.24,.15),(-.13,.08,.12),(.48,-.14,-.59)],
    # Rear mass carries a different tilted fracture face, avoiding a boxy back.
    [(-.48,-.52,.07),(.31,-.53,.10),(.50,-.44,.42),(.31,-.45,.59),
     (-.23,-.52,.63),(-.51,-.46,.42),(-.49,.04,.25),(-.36,.25,.44),
     (-.17,.37,.48),(.03,.31,.57),(.26,.28,.49),(.44,.12,.38),
     (.17,.38,.22),(-.17,.37,.15)],
]

SMALL_FORMS = [
    [(-.61,-.48,-.41),(-.23,-.52,-.55),(.48,-.50,-.47),(.65,-.42,.12),
     (.33,-.50,.50),(-.49,-.48,.44),(-.68,-.05,-.21),(-.49,.18,-.48),
     (-.21,.36,-.46),(.12,.40,-.32),(.36,.33,-.32),(.52,.19,-.16),
     (.64,.05,.16),(.30,.41,.34),(.04,.44,.44),(-.39,.34,.22),
     (-.61,.12,.21),(-.57,-.14,-.47)],
    [(-.53,-.49,-.38),(-.28,-.51,-.57),(.21,-.51,-.59),(.40,-.46,-.29),
     (.03,-.52,-.08),(-.48,-.45,-.12),(-.60,-.21,-.39),(-.41,-.02,-.57),
     (-.18,.12,-.60),(.08,.09,-.57),(.32,-.04,-.42),(.25,.11,-.22),
     (-.15,.16,-.19),(-.52,.03,-.25)],
]


def unit(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


class Rock:
    def __init__(self,variant,seed):
        rng=np.random.default_rng(seed)
        self.phase=rng.uniform(0.,6.28,5)
        self.hulls=[]
        self.variant=variant
        for index,form in enumerate(LARGE_FORMS if variant=='large' else SMALL_FORMS):
            points=np.array(form,dtype=float)
            # Small independent differences preserve the intended silhouette and
            # fracture families without giving every instance identical planes.
            points+=rng.uniform(-.030,.030,points.shape)
            if index==0:
                points[:,1]+=rng.uniform(-.075,.075)*points[:,0]
            hull=ConvexHull(points).equations
            self.hulls.append(hull)
        self.joints=[]
        for center,normal,guide,extent,depth in [
            ((-.32,.11,-.49),(.82,.34,-.45),(0,1,0),(.25,.19),.017),
            ((.08,.22,-.49),(.25,.92,-.27),(1,0,0),(.32,.19),.012),
            ((.46,.08,-.27),(-.45,.69,.56),(0,1,0),(.21,.14),.016),
        ][:3 if variant=='large' else 2]:
            normal=unit(np.array(normal))
            along=unit(np.array(guide)-normal*np.dot(guide,normal))
            across=np.cross(normal,along)
            self.joints.append((np.array(center),normal,along,across,np.array(extent),depth))

    def field(self,p):
        x,y,z=p.T
        surface=np.full(len(p),2.)
        for index,hull in enumerate(self.hulls):
            size=.0045+index*.0015
            distances=p@hull[:,:3].T+hull[:,3]
            # Rounded weathered edges are local; long faces stay geological.
            part=logsumexp(distances/size,axis=1)*size
            surface=-smooth_max(-surface,-part,.012)
        foliation=.16*x+.60*y-.33*z+.025*np.sin(4.8*x+2.7*z)
        phase=self.phase
        relief=(.014*np.sin(7.4*x+3.2*y-4.5*z+phase[0])+
                .008*np.sin(-7.9*x+5.6*y+3.2*z+phase[1])+
                .004*np.sin(foliation*40.+phase[2])+
                .0018*np.sin(foliation*69.+phase[3]))
        surface+=relief
        for index,(center,n,u,v,extent,depth) in enumerate(self.joints):
            local=p-center
            along=local@u
            across=local@v
            seam=local@n+.006*np.sin(along*17.2+across*6.1+phase[index])
            seam+=.0025*np.sin(along*35.1-across*14.1)
            # A weathered lip is a shallow geometric recess, tapered across
            # both coordinates. Avoid rectangular holes and saw-cut gaps.
            falloff=np.exp(-((along/extent[0])**4+(across/extent[1])**4))
            side=np.exp(-(seam/.015)**2)
            surface+=depth*falloff*side
        return surface

    def gradient(self,p):
        values=[]
        for axis in range(3):
            offset=np.zeros(3)
            offset[axis]=.0004
            values.append((self.field(p+offset)-self.field(p-offset))/.0008)
        return unit(np.stack(values,axis=1))



def build(output,variant,seed,target):
    rock=Rock(variant,seed)
    low=np.array([-.83,-.73,-.78])
    high=np.array([.83,.73,.78])
    step=.008
    axes=[np.arange(low[axis],high[axis]+step,step) for axis in range(3)]
    volume=np.empty(tuple(len(axis) for axis in axes),dtype=np.float32)
    yz=np.array(np.meshgrid(axes[1],axes[2],indexing='ij')).reshape(2,-1).T
    for index,x in enumerate(axes[0]):
        p=np.column_stack([np.full(len(yz),x),yz])
        volume[index]=rock.field(p).reshape(len(axes[1]),len(axes[2]))
    points,faces,_,_=marching_cubes(volume,0.,spacing=(step,)*3,gradient_direction='ascent',allow_degenerate=False)
    points+=low
    source_triangles=len(faces)
    source_edges=np.concatenate([faces[:,[0,1]],faces[:,[1,2]],faces[:,[2,0]]])
    source_edges.sort(axis=1)
    _,source_counts=np.unique(source_edges,axis=0,return_counts=True)
    print('SOURCE_TOPOLOGY',int((source_counts==1).sum()),int((source_counts>2).sum()),flush=True)
    # Preserve the finite crack ends during decimation. A simple aggressive
    # collapse pinches narrow lips together and creates nonmanifold edges.
    simplifier=pymeshlab.MeshSet()
    simplifier.add_mesh(pymeshlab.Mesh(points.astype(np.float64),faces.astype(np.int32)))
    simplifier.meshing_decimation_quadric_edge_collapse(
        targetfacenum=target,preservetopology=True,preservenormal=True,
        optimalplacement=False,qualitythr=.40)
    points=simplifier.current_mesh().vertex_matrix()
    faces=simplifier.current_mesh().face_matrix().astype(np.int64)
    triangles=points[faces]
    signed_volume=np.einsum('ij,ij->i',triangles[:,0],np.cross(triangles[:,1],triangles[:,2])).sum()/6.
    if signed_volume<0:
        faces=faces[:,[0,2,1]]
    original=points.copy()
    minp,maxp=points.min(axis=0),points.max(axis=0)
    scale=ENVELOPE/(maxp-minp)
    points=(points-(minp+maxp)*.5)*scale
    normals=unit(rock.gradient(original)/scale)
    triangles=points[faces]
    face_vectors=np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0])
    face_normals=unit(face_vectors)
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=output.with_suffix('.obj.tmp')
    with temp.open('w',encoding='ascii') as stream:
        stream.write(f'o WeatheredGneiss_{variant}_{seed}\ns 1\n')
        for p in points:stream.write('v %.7f %.7f %.7f\n'%tuple(p))
        uv=[]
        corner_normals=[]
        for face,normal in zip(faces,face_normals):
            axis=int(np.argmax(abs(normal)))
            chart=np.eye(3)[axis]*np.sign(normal[axis])
            u=np.array([0.,0.,1.]) if axis==0 else np.array([1.,0.,0.])
            v=np.cross(chart,u)
            uv.extend(np.column_stack([points[face]@u,points[face]@v]))
            for vertex in face:
                n=normals[vertex]
                corner_normals.append(n if np.dot(n,normal)>.25 else normal)
        for row in uv:stream.write('vt %.7f %.7f\n'%tuple(row))
        for n in corner_normals:stream.write('vn %.7f %.7f %.7f\n'%tuple(n))
        for i,face in enumerate(faces):
            stream.write('f '+' '.join(f'{vertex+1}/{i*3+j+1}/{i*3+j+1}' for j,vertex in enumerate(face))+'\n')
    temp.replace(output)
    edges=np.concatenate([faces[:,[0,1]],faces[:,[1,2]],faces[:,[2,0]]])
    edges.sort(axis=1)
    _,count=np.unique(edges,axis=0,return_counts=True)
    stats={'seed':seed,'variant':variant,'grid_step':step,'source_triangles':source_triangles,
           'vertices':len(points),'triangles':len(faces),
           'envelope':list(points.max(axis=0)-points.min(axis=0)),
           'boundary_edges':int((count==1).sum()),'non_manifold_edges':int((count>2).sum()),
           'finite_normals':bool(np.isfinite(corner_normals).all())}
    print(json.dumps(stats))



if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Bake the West Ridge outcrop meshes.')
    parser.add_argument('--output-dir', type=Path,
                        default=Path(__file__).resolve().parent.parent / 'details')
    parser.add_argument('--variant', choices=['both', 'large', 'small'], default='both')
    args = parser.parse_args()
    variants = [
        ('large', 'ridge_outcrop.obj', 3117, 18000),
        ('small', 'ridge_outcrop_small.obj', 719, 10000),
    ]
    for variant, file_name, seed, triangles in variants:
        if args.variant in ['both', variant]:
            build(args.output_dir / file_name, variant, seed, triangles)
