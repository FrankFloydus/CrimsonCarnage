"""Build repeatable 4K PBR maps from the original ImageGen albedo masters."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from math import hypot
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


MATERIALS = Path(__file__).resolve().parent
SIZE = 4096


@dataclass(frozen=True)
class Material:
    source: str
    tile_width_m: float
    relief_m: float
    roughness: float
    roughness_variation: float
    ao_strength: float
    metalness: float = 0.0
    shared: bool = False


PRESETS = {
    "alpine_meadow": Material("masters/alpine_meadow.png", 2.0, 0.0036, 0.88, 0.07, 0.60),
    "snowpack": Material("masters/snowpack.png", 1.6, 0.00046, 0.84, 0.07, 0.28, shared=True),
    "spruce_bark": Material("masters/spruce_bark.png", 1.4, 0.0038, 0.83, 0.08, 0.80),
    "alpine_rock": Material("masters/alpine_rock.png", 2.2, 0.0055, 0.82, 0.12, 0.78),
    "slate_flagstone": Material("slate_flagstone.png", 3.0, 0.0049, 0.72, 0.13, 0.65),
    "alpine_scree": Material("alpine_scree.png", 4.0, 0.0098, 0.91, 0.08, 0.83),
    "weathered_larch": Material("weathered_larch.png", 2.0, 0.0029, 0.73, 0.13, 0.72),
    "standing_seam_zinc": Material("standing_seam_zinc.png", 2.0, 0.0033, 0.39, 0.16, 0.54, 0.89),
}


def periodic_component(image):
    # Moisan's periodic-plus-smooth decomposition removes the border mismatch.
    rows, columns = image.shape
    boundary = np.zeros_like(image)
    boundary[0] = image[-1] - image[0]
    boundary[-1] = -boundary[0]
    boundary[:, 0] += image[:, -1] - image[:, 0]
    boundary[:, -1] += image[:, 0] - image[:, -1]
    eigenvalues = (
        2.0 * np.cos(np.arange(rows)[:, None] * (2.0 * np.pi / rows))
        + 2.0 * np.cos(np.arange(columns // 2 + 1)[None, :] * (2.0 * np.pi / columns))
        - 4.0
    )
    eigenvalues[0, 0] = 1.0
    smooth_spectrum = np.fft.rfft2(boundary) / eigenvalues
    smooth_spectrum[0, 0] = 0.0
    return image - np.fft.irfft2(smooth_spectrum, s=image.shape, axes=(0, 1))


def byte_image(values):
    return np.rint(np.clip(values, 0.0, 1.0) * 255.0).astype(np.uint8)


def albedo_master(source):
    with Image.open(source) as original:
        colors = np.asarray(original.convert("RGB"), dtype=np.float32) / 255.0
    for channel in range(3):
        colors[:, :, channel] = periodic_component(colors[:, :, channel])
    pixels = byte_image(colors)
    padding = 8
    padded = np.pad(pixels, ((padding, padding), (padding, padding), (0, 0)), mode="wrap")
    return np.asarray(
        Image.fromarray(padded).resize(
            (SIZE, SIZE), Image.Resampling.LANCZOS,
            box=(padding, padding, padding + pixels.shape[1], padding + pixels.shape[0]),
        )
    )


def normalized_band(values, scale):
    values /= max(float(values.std()) * scale, 0.00001)
    return np.clip(values, -1.0, 1.0, out=values)


def height_fields(rgb, material, seed):
    linear_curve = np.arange(256, dtype=np.float32) / 255.0
    linear_curve = np.where(
        linear_curve <= 0.04045, linear_curve / 12.92, ((linear_curve + 0.055) / 1.055) ** 2.4,
    )
    luminance = (
        linear_curve[rgb[:, :, 0]] * 0.2126
        + linear_curve[rgb[:, :, 1]] * 0.7152
        + linear_curve[rgb[:, :, 2]] * 0.0722
    )
    luminance = np.log(np.maximum(luminance, 0.015))
    medium = ndimage.gaussian_filter(luminance, 3.0, mode="wrap")
    coarse = ndimage.gaussian_filter(luminance, 13.0, mode="wrap")
    profile = normalized_band(medium - coarse, 3.0)
    fine = normalized_band(luminance - medium, 3.0)

    rng = np.random.default_rng(seed)
    micro = ndimage.gaussian_filter(
        rng.standard_normal(luminance.shape, dtype=np.float32), 0.85, mode="wrap",
    )
    normalized_band(micro, 3.0)
    height = (profile * 0.60 + fine * 0.33 + micro * 0.07) * material.relief_m
    return height, profile, fine


def tangent_normals(height, meters_per_texel):
    # The OpenGL normal convention reverses the downwards image-space Y derivative.
    horizontal = -ndimage.sobel(height, axis=1, mode="wrap") / (8.0 * meters_per_texel)
    vertical = ndimage.sobel(height, axis=0, mode="wrap") / (8.0 * meters_per_texel)
    reciprocal_length = 1.0 / np.sqrt(1.0 + horizontal * horizontal + vertical * vertical)
    encoded = np.empty((*height.shape, 3), dtype=np.uint8)
    encoded[:, :, 0] = byte_image(0.5 + 0.5 * horizontal * reciprocal_length)
    encoded[:, :, 1] = byte_image(0.5 + 0.5 * vertical * reciprocal_length)
    encoded[:, :, 2] = byte_image(0.5 + 0.5 * reciprocal_length)
    return encoded


def ambient_visibility(height, meters_per_texel, strength):
    # Sample the heightfield horizon in eight azimuths, then integrate sky visibility.
    occlusion = np.zeros_like(height)
    directions = ((1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1))
    for dx, dy in directions:
        horizon = np.zeros_like(height)
        for step in (2, 4, 8, 16, 32, 64):
            neighbor = np.roll(height, (dy * step, dx * step), axis=(0, 1))
            slope = (neighbor - height) / (step * hypot(dx, dy) * meters_per_texel)
            np.maximum(horizon, slope, out=horizon)
        horizon *= horizon
        occlusion += horizon / (1.0 + horizon)
    return 1.0 - occlusion * (strength / len(directions))


def save_webp(pixels, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    Image.fromarray(pixels).save(temporary, format="WEBP", lossless=True, method=4)
    temporary.replace(target)


def bake(key):
    material = PRESETS[key]
    destination = MATERIALS / "pbr"
    if material.shared:
        destination = MATERIALS.parents[1] / "surfaces" / "textures"
    source = MATERIALS / material.source
    colors = albedo_master(source)
    save_webp(colors, destination / f"{key}_albedo.webp")

    seed = sum((index + 1) * ord(character) for index, character in enumerate(key))
    height, medium, fine = height_fields(colors, material, seed)
    del colors
    meters_per_texel = material.tile_width_m / SIZE
    save_webp(tangent_normals(height, meters_per_texel), destination / f"{key}_normal.webp")

    roughness = material.roughness + material.roughness_variation * (0.42 * fine - 0.58 * medium)
    orm = np.empty((SIZE, SIZE, 3), dtype=np.uint8)
    orm[:, :, 0] = byte_image(ambient_visibility(height, meters_per_texel, material.ao_strength))
    orm[:, :, 1] = byte_image(np.clip(roughness, 0.06, 0.98))
    # The metal channel describes the authored substrate. Bright dielectric snow remains zero.
    orm[:, :, 2] = byte_image(material.metalness * (1.0 + np.maximum(medium, 0.0) * 0.10))
    save_webp(orm, destination / f"{key}_orm.webp")
    print(f"{key}: albedo, normal and ORM at {SIZE} x {SIZE}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("materials", nargs="*", metavar="MATERIAL")
    parser.add_argument("--jobs", type=int, default=2)
    arguments = parser.parse_args()
    unknown = set(arguments.materials) - PRESETS.keys()
    if unknown:
        parser.error("unknown material: " + ", ".join(sorted(unknown)))
    with ThreadPoolExecutor(max_workers=max(1, arguments.jobs)) as workers:
        list(workers.map(bake, arguments.materials or PRESETS))


if __name__ == "__main__":
    main()
