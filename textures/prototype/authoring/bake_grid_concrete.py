"""Bake the prototype concrete detail maps from the original height reference."""

from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


SIZE = 4096
TILE_METERS = 1.80
RELIEF_METERS = 0.00195
HERE = Path(__file__).resolve().parent


def periodic_component(image):
    """Remove the boundary jump with a periodic Poisson solve."""
    height, width = image.shape
    boundary = np.zeros_like(image)
    boundary[0] += image[-1] - image[0]
    boundary[-1] += image[0] - image[-1]
    boundary[:, 0] += image[:, -1] - image[:, 0]
    boundary[:, -1] += image[:, 0] - image[:, -1]
    x = 2.0 * np.pi * np.arange(width) / width
    y = 2.0 * np.pi * np.arange(height) / height
    eigenvalues = 2.0 * np.cos(y[:, None]) + 2.0 * np.cos(x) - 4.0
    eigenvalues[0, 0] = 1.0
    spectrum = np.fft.fft2(boundary) / eigenvalues
    spectrum[0, 0] = 0.0
    return image - np.fft.ifft2(spectrum).real.astype(np.float32)


def save_map(data, name):
    encoded = np.rint(np.clip(data, 0.0, 1.0) * 255.0).astype(np.uint8)
    destination = HERE.parent / name
    temporary = destination.with_suffix(".webp.baking")
    Image.fromarray(encoded).convert("RGB").save(
        temporary, "WEBP", lossless=True, method=6
    )
    temporary.replace(destination)


def robust_range(data, low_percentile, high_percentile):
    low, high = np.percentile(data, [low_percentile, high_percentile])
    return np.clip((data - low) / max(high - low, 1.0e-6), 0.0, 1.0)


def smooth_curve(data):
    return data * data * (3.0 - 2.0 * data)


def resample(data):
    return ndimage.zoom(
        data, (SIZE / data.shape[0], SIZE / data.shape[1]),
        order=3, mode="grid-wrap", grid_mode=True,
    )


def bake():
    source = Image.open(HERE / "grid_worn_concrete_source.png").convert("L")
    surface = periodic_component(np.asarray(source, dtype=np.float32) / 255.0)
    # Carry the broad wear pattern in roughness, rather than embossing it into the slab.
    coarse = ndimage.gaussian_filter(surface, 38.0, mode="wrap")
    medium = ndimage.gaussian_filter(surface, 5.5, mode="wrap")
    wear = smooth_curve(robust_range(coarse * 0.55 + medium * 0.45, 5.0, 97.0))
    edge = medium - ndimage.gaussian_filter(surface, 18.0, mode="wrap")
    scratches = ndimage.gaussian_filter(surface, 1.35, mode="wrap") - medium
    abrasion = robust_range(edge * 0.63 + scratches * 0.37, 2.0, 98.0) - 0.5
    # Burnished patches have calm normals. Eroded islands keep the irregular detail.
    height = resample(abrasion * (0.20 + 0.80 * wear)) * RELIEF_METERS
    meters_per_texel = TILE_METERS / SIZE
    dx = ndimage.sobel(height, axis=1, mode="wrap") / (8.0 * meters_per_texel)
    dy = ndimage.sobel(height, axis=0, mode="wrap") / (8.0 * meters_per_texel)
    slope_squared = dx * dx + dy * dy
    inverse_length = 1.0 / np.sqrt(1.0 + slope_squared)
    # OpenGL tangent normals reverse the downward image-space Y derivative.
    normal = np.stack((-dx * inverse_length, dy * inverse_length, inverse_length), axis=-1)
    save_map(normal * 0.5 + 0.5, "grid_worn_concrete_normal.webp")

    variation = np.abs(surface - medium)
    scuff = robust_range(ndimage.gaussian_filter(variation, 7.0, mode="wrap"), 8.0, 96.0)
    roughness = resample(0.57 + 0.41 * smooth_curve(wear * 0.87 + scuff * 0.13))
    save_map(roughness, "grid_worn_concrete_roughness.webp")
    angles = np.degrees(np.arctan(np.sqrt(slope_squared)))
    print(f"{source.width} × {source.height} source, {SIZE} × {SIZE} baked maps")
    print("Normal angle p50/p95 degrees:", np.round(np.percentile(angles, [50, 95]), 2))
    print("Linear roughness range:", float(roughness.min()), float(roughness.max()))


if __name__ == "__main__":
    bake()
