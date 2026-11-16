from pathlib import Path
import math
import numpy as np

HERE = Path(__file__).resolve().parent
UP = np.array([0.,1.,0.])

def unit(v):
    return v / max(np.linalg.norm(v), 1e-8)

def build(segments):
    rng = np.random.default_rng(73182)
    verts, uvs, colors, indices = [], [], [], []
    def vertex(point, uv, color):
        verts.append(point.tolist())
        uvs.append(list(uv))
        colors.append(list(color))
        return len(verts)-1
    def quad(a,b,c,d):
        # Godot's front-face winding is clockwise.
        indices.extend([a,c,b,a,d,c])
    for frond in range(11):
        angle = frond*2.399963 + rng.uniform(-.25,.25)
        radial = np.array([math.cos(angle),0.,math.sin(angle)])
        across = np.cross(radial, UP)
        outside = frond < 8
        height = rng.uniform(.42,.58) if outside else rng.uniform(.68,.82)
        reach = rng.uniform(.70,.85) if outside else rng.uniform(.30,.50)
        arch = .91 if outside else .60
        root = radial * rng.uniform(.02,.07)
        half_width = rng.uniform(.18,.215) if outside else rng.uniform(.14,.175)
        roll = rng.uniform(-.16,.16)
        tint = (rng.uniform(.94,1.02), rng.uniform(.92,1.), rng.uniform(.88,1.))
        warp = rng.uniform(.91,1.07)
        source_offset = 3 * (frond % 2)
        def point(t):
            return root + radial*reach*t + UP*(height*math.sin(math.pi*arch*t)+.012*t)
        for j in range(segments+1):
            t = j/segments
            tangent = unit(point(min(1,t+.01))-point(max(0,t-.01)))
            normal = unit(np.cross(across,tangent))
            side = across*math.cos(roll)+normal*math.sin(roll)
            for fraction in [-1.,-.5,0.,.5,1.]:
                p = point(t)+side*half_width*fraction
                p += normal*half_width*(.13*fraction*fraction+.04*math.sin(t*math.pi*3+frond))
                u=(fraction+1)*.5
                if frond%3 == 1:
                    u=1-u
                vertex(p,(u+source_offset,1-t**warp),tint)
        base = len(verts)-(segments+1)*5
        for j in range(segments):
            for k in range(4):
                a=base+j*5+k
                quad(a,a+1,a+6,a+5)
        # The small basal stipe remains genuinely three-dimensional edge-on.
        stem_base = len(verts)
        for j in range(5):
            t=.18*j/4
            tangent=unit(point(t+.001)-point(max(0,t-.001)))
            a=unit(np.cross(tangent,radial))
            b=np.cross(tangent,a)
            for k in range(5):
                q=k*math.tau/4
                vertex(point(t)+.0035*(a*math.cos(q)+b*math.sin(q)),(2.3+k*.1+source_offset,t),(.94,.95,.84))
        for j in range(4):
            for k in range(4):
                a=stem_base+j*5+k
                quad(a,a+1,a+6,a+5)
    normals=np.zeros((len(verts),3))
    for a,b,c in np.asarray(indices).reshape(-1,3):
        # Stored indices were reversed for Godot. Preserve the physical normals.
        n=np.cross(np.asarray(verts[c])-verts[a],np.asarray(verts[b])-verts[a])
        normals[a]+=n
        normals[b]+=n
        normals[c]+=n
    return {'positions':verts,'uvs':uvs,'colors':colors,'normals':[unit(n).tolist() for n in normals], 'indices':indices}


def save_obj(name, data, scale):
    with (HERE / (name + '.obj')).open('w', encoding='ascii') as output:
        output.write('# Original curved lady-fern frond mesh\no ' + name + '\ns 1\n')
        for point, color in zip(data['positions'], data['colors']):
            values = [*(axis * scale for axis in point), *color]
            output.write('v ' + ' '.join(f'{value:.7f}' for value in values) + '\n')
        for u, v in data['uvs']:
            # Godot inverts Wavefront V on import.
            output.write(f'vt {u:.7f} {1.0 - v:.7f}\n')
        for normal in data['normals']:
            output.write('vn ' + ' '.join(f'{axis:.7f}' for axis in normal) + '\n')
        for a, c, b in np.asarray(data['indices']).reshape(-1, 3):
            # Export ordinary Wavefront winding. The importer reverses it.
            output.write('f ' + ' '.join(f'{index+1}/{index+1}/{index+1}' for index in (a,b,c)) + '\n')
    print(name, len(data['indices'])//3, 'triangles', flush=True)


if __name__ == '__main__':
    for suffix, segments in [('near', 18), ('mid', 8)]:
        mesh_data = build(segments)
        save_obj('lady_fern_frond_' + suffix, mesh_data, 1.0)
        save_obj('young_fern_frond_' + suffix, mesh_data, 0.62)
