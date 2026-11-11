# Original modeled ground vegetation. No alpha cards or bitmap artwork are generated.
from pathlib import Path
import math
import numpy as np

HERE = Path(__file__).resolve().parent
UP = np.array([0.0, 1.0, 0.0])
TAU = math.tau


def unit(v):
    return v / max(float(np.linalg.norm(v)), 1e-8)


def frame(d):
    axis = UP if abs(d[1]) < 0.95 else np.array([1.0, 0.0, 0.0])
    a = unit(np.cross(d, axis))
    return a, np.cross(d, a)


class Mesh:
    def __init__(self, seed):
        self.rng = np.random.default_rng(seed)
        self.vertices, self.uvs, self.colors, self.faces = [], [], [], []

    def vertex(self, p, uv, color):
        self.vertices.append(np.array(p))
        self.uvs.append(uv)
        self.colors.append(color)
        return len(self.vertices) - 1

    def quad(self, a, b, c, d):
        self.faces += [(a, b, c), (a, c, d)]

    def tube(self, points, radius, wood=True, sides=4):
        rings = []
        for i, p in enumerate(points):
            tangent = unit(points[min(i + 1, len(points) - 1)] - points[max(i - 1, 0)])
            a, b = frame(tangent)
            ring = []
            for j in range(sides + 1):
                angle = TAU * j / sides
                r = radius * (1.0 - 0.88 * i / (len(points) - 1))
                uv = (1.23 + j / sides * 0.55, i / (len(points) - 1)) if wood else (2.2 + j / sides, i / (len(points) - 1))
                ring.append(self.vertex(p + r * (a * math.cos(angle) + b * math.sin(angle)), uv, (0.88, 0.90, 0.82)))
            rings.append(ring)
        for low, high in zip(rings, rings[1:]):
            for j in range(sides):
                self.quad(low[j], low[j + 1], high[j + 1], high[j])

    def leaf(self, base, direction, length, width, roll=0.0, lobes=0, segments=4, dry=False, plane_normal=None):
        d = unit(direction)
        a, n = frame(d)
        if plane_normal is not None:
            # A compound fern is a folded sheet around its curved rachis. Align
            # leaflets to that local sheet rather than the horizontal world plane.
            a = unit(np.cross(d, plane_normal))
            n = unit(np.cross(a, d))
        across = a * math.cos(roll) + n * math.sin(roll)
        normal = unit(np.cross(across, d))
        shade = self.rng.uniform(0.82, 1.05)
        color = (shade, shade * self.rng.uniform(0.97, 1.03), shade * self.rng.uniform(0.86, 1.05))
        rows = []
        for i in range(segments + 1):
            t = i / segments
            outline = max(math.sin(math.pi * t), 0.012) ** 0.70
            if lobes:
                outline *= 0.70 + 0.30 * abs(math.cos(math.pi * t * lobes))
            center = base + d * length * t + normal * length * 0.12 * math.sin(math.pi * t)
            row = []
            for edge in [-1.0, 0.0, 1.0]:
                p = center + across * width * outline * edge
                p -= normal * width * 0.16 * abs(edge) * outline
                row.append(self.vertex(p, ((edge + 1.0) * 0.5 + (2.2 if dry else 0.0), t), color))
            rows.append(row)
        for low, high in zip(rows, rows[1:]):
            for j in range(2):
                self.quad(low[j], low[j + 1], high[j + 1], high[j])

    def save(self, name):
        normals = np.zeros((len(self.vertices), 3))
        for a, b, c in self.faces:
            n = np.cross(self.vertices[b] - self.vertices[a], self.vertices[c] - self.vertices[a])
            normals[a] += n
            normals[b] += n
            normals[c] += n
        with (HERE / (name + '.obj')).open('w', encoding='ascii') as f:
            f.write('# Original modeled alpine ground plant\no ' + name + '\ns 1\n')
            for p, color in zip(self.vertices, self.colors):
                f.write('v ' + ' '.join(f'{x:.7f}' for x in [*p, *color]) + '\n')
            for u, v in self.uvs:
                f.write(f'vt {u:.7f} {v:.7f}\n')
            for n in normals:
                f.write('vn ' + ' '.join(f'{x:.7f}' for x in unit(n)) + '\n')
            for face in self.faces:
                f.write('f ' + ' '.join(f'{i+1}/{i+1}/{i+1}' for i in face) + '\n')
        print(name, len(self.faces), 'triangles', flush=True)


def fern(name, seed, height, reach, detailed):
    m = Mesh(seed)
    # Geometry-level randomness is independent of leaflet/color consumption, so
    # near and middle meshes retain identical curved fronds across a LOD change.
    form_rng = np.random.default_rng(seed)
    for frond in range(8):
        yaw = frond * 2.399963 + form_rng.uniform(-0.23, 0.23)
        radial = np.array([math.cos(yaw), 0.0, math.sin(yaw)])
        across = np.array([-radial[2], 0.0, radial[0]])
        h, r = height * form_rng.uniform(0.75, 1.12), reach * form_rng.uniform(0.76, 1.14)
        def point(t):
            return radial * r * t + UP * (h * math.sin(t * math.pi * 0.80) + 0.025 * t)
        m.tube([point(t) for t in np.linspace(0, 1, 11)], 0.0035, sides=4)
        for level in range(16):
            t = 0.08 + level * 0.054
            tangent = unit(point(min(t + 0.01, 1.0)) - point(max(t - 0.01, 0.0)))
            plane_normal = unit(np.cross(across, tangent))
            length = 0.245 * math.sin(t * math.pi) ** 0.75 * (1.0 - t * 0.65)
            length *= height / 0.82 * form_rng.uniform(0.90, 1.08)
            for side in [-1, 1]:
                d = unit(across * side + tangent * (0.17 + t * 0.32))
                base = point(t)
                if not detailed:
                    m.leaf(base, d, length, length * 0.22, lobes=8, segments=8, plane_normal=plane_normal)
                    continue
                m.tube([base, base + d * length * 0.5, base + d * length], 0.0009, sides=3)
                lateral = unit(tangent - d * np.dot(tangent, d))
                for index in range(6):
                    u = 0.13 + index * 0.135
                    center = base + d * length * u
                    size = length * (0.25 * (1.0 - u) ** 0.50 + 0.028)
                    for hand in [-1, 1]:
                        ld = unit(lateral * hand + d * 0.46)
                        m.leaf(center, ld, size, size * 0.31, roll=m.rng.uniform(-0.12, 0.12), lobes=3, segments=3, plane_normal=plane_normal)
                m.leaf(base + d * length * 0.83, d, length * 0.21, length * 0.065, segments=3, plane_normal=plane_normal)
        tip_direction = point(1.0) - point(.88)
        tip_normal = unit(np.cross(across, tip_direction))
        m.leaf(point(.88), tip_direction, float(np.linalg.norm(tip_direction)),
               .013 * height / .82, segments=5, plane_normal=tip_normal)
    m.save(name)


def shrub():
    m = Mesh(99417)
    for stem in range(13):
        yaw = stem * 2.399963
        radial = np.array([math.cos(yaw), 0.0, math.sin(yaw)])
        h = m.rng.uniform(0.27, 0.52)
        points = [radial * 0.035, radial * 0.10 + UP * h * 0.45, radial * 0.20 + UP * h]
        m.tube(points, 0.0024, sides=4)
        for j in range(5):
            t = 0.25 + j * 0.145
            center = radial * 0.20 * t + UP * h * t
            for side in [-1, 1]:
                direction = unit(np.cross(radial, UP) * side + radial * 0.30 + UP * 0.56)
                size = m.rng.uniform(0.033, 0.055)
                m.leaf(center, direction, size, size * 0.32, roll=m.rng.uniform(-0.5, 0.5), segments=5, dry=m.rng.random() < 0.06)
    m.save('bilberry_shrub')


def sorrel():
    m = Mesh(44318)
    for stem in range(20):
        yaw = m.rng.uniform(0, TAU)
        radial = np.array([math.cos(yaw), 0.0, math.sin(yaw)])
        h = m.rng.uniform(0.11, 0.25)
        end = radial * m.rng.uniform(0.025, 0.14) + UP * h
        m.tube([np.zeros(3), end * 0.55, end], 0.0011, sides=3)
        for leaf in range(3):
            angle = yaw + TAU * leaf / 3
            direction = np.array([math.cos(angle), m.rng.uniform(0.05, 0.26), math.sin(angle)])
            m.leaf(end, direction, m.rng.uniform(0.028, 0.043), 0.019, segments=5)
    m.save('wood_sorrel')


def grass(name, seed, count, height):
    m = Mesh(seed)
    for blade in range(count):
        yaw = m.rng.uniform(0, TAU)
        radial = np.array([math.cos(yaw), 0.0, math.sin(yaw)])
        across = np.array([-radial[2], 0.0, radial[0]])
        root = radial * m.rng.uniform(0.01, 0.10)
        h = height * m.rng.uniform(0.52, 1.18)
        reach = h * m.rng.uniform(0.24, 0.88)
        dry = m.rng.random() < 0.16
        width = m.rng.uniform(0.0024, 0.0052)
        rows = []
        for j in range(7):
            t = j / 6
            center = root + radial * reach * t * t + UP * h * (t - 0.22 * t ** 3)
            w = width * (1.0 - t) ** 0.65 + 0.00008
            row = []
            for side in [-1, 0, 1]:
                p = center + across * side * w + UP * (1 - abs(side)) * w * 0.28
                row.append(m.vertex(p, ((side+1)*.5 + (2.2 if dry else 0), t), (1.0, m.rng.uniform(.94,1.04), .91)))
            rows.append(row)
        for a, b in zip(rows, rows[1:]):
            m.quad(a[0],a[1],b[1],b[0])
            m.quad(a[1],a[2],b[2],b[1])
    m.save(name)


def seedheads():
    m = Mesh(31972)
    # Loose branched panicles, with actual small florets rather than flat crosses.
    for stem in range(11):
        yaw = m.rng.uniform(0.0, TAU)
        radial = np.array([math.cos(yaw), 0.0, math.sin(yaw)])
        side = np.cross(radial, UP)
        h = m.rng.uniform(0.48, 0.78)
        root = radial * m.rng.uniform(0.02, 0.10)
        end = root + radial * h * 0.22 + UP * h
        points = [root, root + radial * h * 0.05 + UP * h * .48, end]
        m.tube(points, 0.0011, wood=False, sides=3)
        for leaf_level in [.22, .43]:
            base = root + (end - root) * leaf_level
            m.leaf(base, radial + UP * .7, .13, .004, dry=stem % 3 == 0)
        for level in range(5):
            t = level / 4
            center = end - UP * (.13 * (1.0 - t))
            for hand in [-1, 1]:
                reach = .026 * (1.0 - .65 * t)
                tip = center + side * hand * reach + radial * .008 + UP * .025
                m.tube([center, tip], .0006, wood=False, sides=3)
                for floret in range(3):
                    base = tip + UP * floret * .004
                    direction = unit(UP + side * hand * (.15 + .22 * floret))
                    m.leaf(base, direction, .013, .003, segments=3, dry=True,
                           plane_normal=radial)
                    m.leaf(base, direction, .013, .0025, roll=math.pi * .5,
                           segments=3, dry=True, plane_normal=radial)
    m.save('meadow_panicle')


fern('lady_fern', 41820, 0.82, 0.70, True)
fern('lady_fern_mid', 41820, 0.82, 0.70, False)
fern('young_fern', 51523, 0.46, 0.43, True)
fern('young_fern_mid', 51523, 0.46, 0.43, False)
shrub()
sorrel()
grass('fescue_bunch', 92316, 66, 0.27)
grass('sedge_tussock', 99184, 52, 0.59)
seedheads()
