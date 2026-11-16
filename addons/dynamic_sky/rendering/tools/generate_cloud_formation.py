"""Bake original linear data for the volumetric cloud field.

Requires NumPy, SciPy and Pillow. Uses deterministic gradient fields and authored
profile curves; the generator has no dependency on vendor textures or projects.
"""

import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image
from scipy.interpolate import PchipInterpolator

sys.dont_write_bytecode = True
from generate_sky_textures import gradient_noise, texture_atlas

TOOL_FOLDER = Path(__file__).resolve().parent
OUTPUT = TOOL_FOLDER.parent
SIZE = 128
COLUMNS = 8


def fractal_gradient(random, frequency=8, weights=(0.65, 0.25, 0.10)):
    return sum(
        weight * gradient_noise(SIZE, 3, frequency * 2**octave, random)
        for octave, weight in enumerate(weights)
    )


def save_linear(path, values):
    pixels = np.rint(np.clip(values, 0.0, 1.0) * 255.0).astype(np.uint8)
    Image.fromarray(pixels).save(path, optimize=True)


def bake_volume_fields():
    random = np.random.default_rng(731908)
    coverage = fractal_gradient(random) - 0.5
    independent = fractal_gradient(random) - 0.5
    floor = fractal_gradient(random, frequency=6) - 0.5
    formation = np.stack([
        0.27 + 0.72 * coverage + 0.60 * (coverage * coverage - 0.012),
        0.27 + 0.40 * coverage + 0.60 * independent + 0.40 * (independent * independent - 0.012),
        0.45 + 0.25 * coverage + 0.70 * floor,
    ], axis=-1)
    erosion = np.stack([
        0.50 + 0.98 * (fractal_gradient(random) - 0.50),
        0.49 + 1.05 * (fractal_gradient(random) - 0.50),
        0.50 + 0.80 * (fractal_gradient(random, weights=(0.85, 0.12, 0.03)) - 0.50),
    ], axis=-1)
    save_linear(OUTPUT / "cloud_formation.png", texture_atlas(formation, COLUMNS))
    save_linear(OUTPUT / "cloud_erosion_volume.png", texture_atlas(erosion, COLUMNS))


def bake_profile():
    profiles = json.loads((TOOL_FOLDER / "cloud_profile_curves.json").read_text(encoding="utf-8"))["profiles"]
    keys = np.array([profile["coverage"] for profile in profiles])
    altitude = 1.0 - np.linspace(0.0, 1.0, 256)
    data = np.ones((256, 64, 4), dtype=np.float64)
    channels = ("taper", "extinction", "erosion")
    interpolators = []
    for profile in profiles:
        curves = []
        for name in channels:
            knots = np.array(profile[name])
            curves.append(PchipInterpolator(knots[:, 0], knots[:, 1]))
        interpolators.append(curves)
    for column, coverage in enumerate(np.linspace(0.0, 1.0, 64)):
        high = min(max(np.searchsorted(keys, coverage, side="right"), 1), len(keys) - 1)
        low = high - 1
        weight = np.clip((coverage - keys[low]) / (keys[high] - keys[low]), 0.0, 1.0)
        height = profiles[low]["height"] * (1.0 - weight) + profiles[high]["height"] * weight
        h = np.clip(altitude / height, 0.0, 1.0)
        for index in range(len(channels)):
            data[:, column, index] = interpolators[low][index](h) * (1.0 - weight) + interpolators[high][index](h) * weight
            if index < 2:
                data[altitude > height, column, index] = 0.0
    # The lowest profile row suppresses density exactly at the condensation boundary.
    data[-1, :, 0] = 0.0
    save_linear(OUTPUT / "cloud_profile.png", data)


if __name__ == "__main__":
    bake_volume_fields()
    bake_profile()
