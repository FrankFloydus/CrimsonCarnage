"""Bake exact OBJ triangle heights beneath the saved demo's lake plane."""

from pathlib import Path
import re

import numpy as np
from PIL import Image


HERE = Path(__file__).resolve().parent
SCENE = HERE.parent / "dynamic_sky_demo.tscn"
TERRAIN = HERE / "lookout_terrain.obj"
OUTPUT = HERE / "lake_bathymetry.png"
WIDTH, HEIGHT = 512, 768
MIN_DEPTH, MAX_DEPTH = -32.0, 64.0


def lake_bounds():
    scene = SCENE.read_text(encoding="utf-8")
    mesh = re.search(r'\[sub_resource type="PlaneMesh" id="lake_mesh"\]([^\[]+)', scene)[1]
    node = re.search(r'\[node name="Lake"[^\]]+\]([^\[]+)', scene)[1]
    width, length = map(float, re.search(r"size = Vector2\(([^)]+)\)", mesh)[1].split(", "))
    transform = list(map(float, re.search(r"transform = Transform3D\(([^)]+)\)", node)[1].split(", ")))
    if transform[:9] != [1, 0, 0, 0, 1, 0, 0, 0, 1]:
        raise ValueError("The lake plane must be axis-aligned in the terrain OBJ's coordinates.")
    x, y, z = transform[9:]
    return x - width * 0.5, x + width * 0.5, z - length * 0.5, z + length * 0.5, y


def terrain_triangles():
    vertices, faces = [], []
    with TERRAIN.open(encoding="utf-8") as mesh:
        for line in mesh:
            if line.startswith("v "):
                vertices.append(tuple(map(float, line.split()[1:4])))
            elif line.startswith("f "):
                indices = [int(part.split("/")[0]) - 1 for part in line.split()[1:]]
                if len(indices) != 3:
                    raise ValueError("Expected triangulated terrain.")
                faces.append(indices)
    return np.asarray(vertices)[np.asarray(faces)]


def bake():
    left, right, top, bottom, surface = lake_bounds()
    minimum = np.array([left, top])
    density = np.array([WIDTH / (right - left), HEIGHT / (bottom - top)])
    triangles = terrain_triangles()
    xz = triangles[:, :, (0, 2)]
    low = np.min(xz, axis=1)
    high = np.max(xz, axis=1)
    intersects = np.all(high >= minimum, axis=1) & np.all(low <= [right, bottom], axis=1)
    elevations = np.full((HEIGHT, WIDTH), -np.inf)
    for triangle in triangles[intersects]:
        a, b, c = (triangle[:, (0, 2)] - minimum) * density - 0.5
        start = np.maximum(np.floor(np.minimum(np.minimum(a, b), c)).astype(int), 0)
        end = np.minimum(np.ceil(np.maximum(np.maximum(a, b), c)).astype(int), [WIDTH - 1, HEIGHT - 1])
        if np.any(start > end):
            continue
        ax, az = b - a
        bx, bz = c - a
        determinant = ax * bz - az * bx
        if abs(determinant) < 1e-12:
            continue
        x, z = np.meshgrid(np.arange(start[0], end[0] + 1) - a[0], np.arange(start[1], end[1] + 1) - a[1])
        u = (x * bz - z * bx) / determinant
        v = (ax * z - az * x) / determinant
        inside = (u >= -1e-8) & (v >= -1e-8) & (u + v <= 1.0 + 1e-8)
        h0, h1, h2 = triangle[:, 1]
        heights = h0 + u * (h1 - h0) + v * (h2 - h0)
        region = elevations[start[1] : end[1] + 1, start[0] : end[0] + 1]
        np.maximum(region, np.where(inside, heights, -np.inf), out=region)

    if not np.isfinite(elevations).all():
        raise ValueError("Some lake texels are missing terrain coverage.")
    depth = surface - elevations
    normalized = np.clip((depth - MIN_DEPTH) / (MAX_DEPTH - MIN_DEPTH), 0.0, 1.0)
    packed = np.round(normalized * 65535.0).astype(np.uint16)
    channels = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    channels[:, :, 0] = packed >> 8
    channels[:, :, 1] = packed & 255
    Image.fromarray(channels).save(OUTPUT, optimize=True)
    print(f"{WIDTH}x{HEIGHT}, bed depth {depth.min():.2f} to {depth.max():.2f} m")
    edges = np.concatenate([depth[0], depth[-1], depth[:, 0], depth[:, -1]])
    print(f"deepest plane edge {edges.max():.2f} m, submerged texels {(depth > 0).mean():.1%}")


if __name__ == "__main__":
    bake()
