"""Bake original periodic density fields for a shallow cloud shell.

The red channel contains separated convective cells assembled from overlapping
thermal lobes. The green channel contains stratiform density. The atlas uses
16 columns and 12 rows of 192 x 64 slices, read left to right.
"""

from math import cos, pi, sin
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter


HORIZONTAL = 192
VERTICAL = 64
COLUMNS = 16
RANDOM = np.random.default_rng(96851)


def smoothstep(lower, upper, sample):
    value = np.clip((sample - lower) / (upper - lower), 0.0, 1.0)
    return value * value * (3.0 - 2.0 * value)


def stamp_lobe(field, x, y, z, horizontal, vertical, aspect, angle, density):
    bound = horizontal * max(1.0, aspect)
    ix = np.arange(int(np.floor((x - bound) * HORIZONTAL)), int(np.ceil((x + bound) * HORIZONTAL)) + 1)
    iz = np.arange(int(np.floor((z - bound) * HORIZONTAL)), int(np.ceil((z + bound) * HORIZONTAL)) + 1)
    iy = np.arange(max(0, int(np.floor((y - vertical) * (VERTICAL - 1)))),
                   min(VERTICAL, int(np.ceil((y + vertical) * (VERTICAL - 1))) + 1))
    if not len(iy):
        return
    dx = ix[None, None, :] / HORIZONTAL - x
    dy = iy[None, :, None] / (VERTICAL - 1) - y
    dz = iz[:, None, None] / HORIZONTAL - z
    direction_x = dx * cos(angle) - dz * sin(angle)
    direction_z = dx * sin(angle) + dz * cos(angle)
    radius = np.sqrt((direction_x / horizontal)**2 + (dy / vertical)**2 + (direction_z / (horizontal * aspect))**2)
    puff = (1.0 - smoothstep(0.34, 1.0, radius)) * density
    region = np.ix_(iz % HORIZONTAL, iy, ix % HORIZONTAL)
    field[region] = np.maximum(field[region], puff)


def bake_convection(altitude):
    field = np.zeros((HORIZONTAL, VERTICAL, HORIZONTAL), np.float32)
    divisions = 10
    for z_cell in range(divisions):
        for x_cell in range(divisions):
            if RANDOM.uniform(0.0, 1.0) < 0.11:
                continue
            x = (x_cell + RANDOM.uniform(-0.18, 1.15)) / divisions
            z = (z_cell + RANDOM.uniform(-0.18, 1.15)) / divisions
            radius = RANDOM.uniform(0.026, 0.066)
            height = RANDOM.uniform(0.44, 0.98)
            density = RANDOM.uniform(0.67, 1.0)
            aspect = RANDOM.uniform(0.73, 1.23)
            angle = RANDOM.uniform(0.0, 2.0 * pi)
            stamp_lobe(field, x, height * 0.40, z, radius * 0.78, height * 0.52, aspect, angle, density)
            for lobe in range(23):
                heading = lobe * 2.399963 + RANDOM.uniform(-0.24, 0.24)
                spread = np.sqrt(RANDOM.uniform(0.09, 1.72))
                lobe_radius = radius * RANDOM.uniform(0.19, 0.55)
                center_height = height * (0.28 + 0.24 * (1.0 - spread) + RANDOM.uniform(-0.10, 0.16))
                top = height * RANDOM.uniform(0.17, 0.57)
                stamp_lobe(
                    field, x + cos(heading) * radius * spread, center_height,
                    z + sin(heading) * radius * spread, lobe_radius,
                    top, RANDOM.uniform(0.77, 1.19), heading, density * RANDOM.uniform(0.77, 1.0),
                )
    # The condensation boundary is level while convective tops have independent puffs.
    field *= smoothstep(0.010, 0.090, altitude)
    field *= 1.0 - smoothstep(0.92, 1.0, altitude)
    return field


def bake_stratiform(altitude):
    raw = RANDOM.normal(size=(HORIZONTAL, HORIZONTAL))
    broad = gaussian_filter(raw, 9.0, mode="wrap")
    detail = gaussian_filter(raw, 3.5, mode="wrap")
    field = np.clip(0.57 + broad / np.std(broad) * 0.09 + detail / np.std(detail) * 0.034, 0.22, 0.91)
    base = 0.035 + (1.0 - field[:, None, :]) * 0.080
    top = 0.50 + field[:, None, :] * 0.37
    profile = smoothstep(base, base + 0.12, altitude) * (1.0 - smoothstep(top * 0.65, top, altitude))
    return field[:, None, :] * profile


def bake(output):
    altitude = np.linspace(0.0, 1.0, VERTICAL, dtype=np.float32)[None, :, None]
    convection = bake_convection(altitude)
    stratiform = bake_stratiform(altitude)
    volume = np.stack((convection, stratiform, np.zeros_like(convection)), axis=-1)
    packed = np.rint(np.clip(volume, 0.0, 1.0) * 255.0).astype(np.uint8)
    rows = HORIZONTAL // COLUMNS
    atlas = packed.reshape(rows, COLUMNS, VERTICAL, HORIZONTAL, 3).transpose(0, 2, 1, 3, 4)
    Image.fromarray(atlas.reshape(rows * VERTICAL, COLUMNS * HORIZONTAL, 3)).save(output, optimize=True)


if __name__ == "__main__":
    bake(Path(__file__).resolve().parents[1] / "cloud_formation.png")
