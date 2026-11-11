# Bake original cliff color and separately authored structural height into editable PBR data.
# The 4096-square results are derived storage maps, not native 4K source photography.

import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

from bake_materials import (
    MATERIALS,
    SIZE,
    albedo_master,
    ambient_visibility,
    byte_image,
    periodic_component,
    save_webp,
    tangent_normals,
)


PREFIX = "mountain_granodiorite"
DETAIL_TILE_METERS = 12.0
MACRO_TILE_METERS = 36.0
DETAIL_HEIGHT_RANGE_METERS = 0.16
MACRO_HEIGHT_RANGE_METERS = 0.45
GRAIN_HEIGHT_RANGE_METERS = 0.00010


def save_png(pixels, target):
    temporary = target.with_suffix(".tmp")
    Image.fromarray(pixels).save(temporary, format="PNG", compress_level=6)
    temporary.replace(target)


def structural_height(source):
    with Image.open(source) as image:
        height = np.asarray(image.convert("L"), dtype=np.float32) / 255.0
        source_size = image.size
    height = periodic_component(height)
    # Suppress residual image-generation speckle without deriving recesses from mineral color.
    height = ndimage.gaussian_filter(height, 0.85, mode="wrap")
    lower, upper = np.percentile(height, (0.5, 99.5))
    height = np.clip((height - lower) / max(float(upper - lower), 0.001), 0.0, 1.0)
    padding = 8
    padded = np.pad(height, padding, mode="wrap")
    height = np.asarray(Image.fromarray(padded).resize(
        (SIZE, SIZE), Image.Resampling.BICUBIC,
        box=(padding, padding, padding + source_size[0], padding + source_size[1]),
    ), dtype=np.float32)
    return np.clip(height, 0.0, 1.0), source_size


def slope_statistics(height, meters_per_texel):
    dx = ndimage.sobel(height, axis=1, mode="wrap") / (8.0 * meters_per_texel)
    dy = ndimage.sobel(height, axis=0, mode="wrap") / (8.0 * meters_per_texel)
    angles = np.degrees(np.arctan(np.hypot(dx, dy)))
    return {str(q): float(value) for q, value in zip(
        (25, 50, 75, 95, 99, 99.9), np.percentile(angles, (25, 50, 75, 95, 99, 99.9)),
    )}


def seam_statistics(data):
    data = data.astype(np.float32)
    return {
        "horizontal_wrap_mean": float(np.mean(np.abs(data[:, 0] - data[:, -1]))),
        "vertical_wrap_mean": float(np.mean(np.abs(data[0] - data[-1]))),
        "horizontal_interior_mean": float(np.mean(np.abs(np.diff(data, axis=1)))),
        "vertical_interior_mean": float(np.mean(np.abs(np.diff(data, axis=0)))),
    }


def write_material(height, physical_width, destination, suffix="", mineral_variation=None):
    meters_per_texel = physical_width / SIZE
    normal = tangent_normals(height, meters_per_texel)
    save_webp(normal, destination / f"{PREFIX}{suffix}_normal.webp")
    ao = ambient_visibility(height, meters_per_texel, 0.72)
    quiet_planes = ndimage.gaussian_filter(height, 48.0, mode="wrap")
    plane_range = max(float(np.ptp(quiet_planes)), 0.001)
    planes = (quiet_planes - float(quiet_planes.mean())) / plane_range
    roughness = 0.81 + (1.0 - ao) * 0.10 + planes * 0.025
    if mineral_variation is not None:
        roughness += mineral_variation * 0.015
    roughness = np.clip(roughness, 0.73, 0.92)
    orm = np.empty((SIZE, SIZE, 3), dtype=np.uint8)
    orm[:, :, 0] = byte_image(ao)
    orm[:, :, 1] = byte_image(roughness)
    orm[:, :, 2] = 0
    save_webp(orm, destination / f"{PREFIX}{suffix}_orm.webp")
    height_range = DETAIL_HEIGHT_RANGE_METERS if not suffix else MACRO_HEIGHT_RANGE_METERS
    encoded_height = np.rint(np.clip(height / height_range, 0.0, 1.0) * 65535.0).astype(np.uint16)
    save_png(encoded_height, destination / f"{PREFIX}{suffix}_height.png")
    if not suffix:
        save_png(orm[:, :, 0], destination / f"{PREFIX}_ao.png")
        save_png(orm[:, :, 1], destination / f"{PREFIX}_roughness.png")
        save_png(orm[:, :, 2], destination / f"{PREFIX}_metallic.png")
    return {
        "tile_width_meters": physical_width,
        "height_range_meters": height_range,
        "normal_slope_degrees_percentiles": slope_statistics(height, meters_per_texel),
        "ao_range": [float(ao.min()), float(ao.max())],
        "roughness_range": [float(roughness.min()), float(roughness.max())],
        "metallic_range": [0.0, 0.0],
        "height_wrap": seam_statistics(height),
        "normal_wrap": seam_statistics(normal),
    }


def bake():
    destination = MATERIALS / "pbr"
    destination.mkdir(exist_ok=True)
    colors = albedo_master(MATERIALS / f"masters/{PREFIX}.png")
    save_webp(colors, destination / f"{PREFIX}_albedo.webp")
    albedo_statistics = seam_statistics(colors / 255.0)
    # Mineral color affects subtle roughness only. It is never structural height.
    luminance = colors.astype(np.float32).mean(axis=2) / 255.0
    mineral = luminance - ndimage.gaussian_filter(luminance, 5.0, mode="wrap")
    mineral = np.clip(mineral / max(float(mineral.std()) * 3.0, 0.001), -1.0, 1.0)
    del colors, luminance
    structure, source_size = structural_height(MATERIALS / f"masters/{PREFIX}_height.png")
    rng = np.random.default_rng(145932)
    grain = ndimage.gaussian_filter(rng.standard_normal((SIZE, SIZE), dtype=np.float32), 0.9, mode="wrap")
    grain /= max(float(np.max(np.abs(grain))), 0.001)
    detail = np.clip(structure * DETAIL_HEIGHT_RANGE_METERS + grain * (GRAIN_HEIGHT_RANGE_METERS * 0.5), 0.0, DETAIL_HEIGHT_RANGE_METERS)
    del grain
    metadata = {
        "source_dimensions": list(source_size),
        "derived_dimensions": [SIZE, SIZE],
        "height_source": f"masters/{PREFIX}_height.png",
        "grain_full_height_range_meters": GRAIN_HEIGHT_RANGE_METERS,
        "albedo_multiplier": 1.0,
        "albedo_wrap": albedo_statistics,
        "detail": write_material(detail, DETAIL_TILE_METERS, destination, mineral_variation=mineral),
    }
    del detail, mineral
    macro = ndimage.gaussian_filter(structure, 8.0, mode="wrap") * MACRO_HEIGHT_RANGE_METERS
    metadata["macro"] = write_material(macro, MACRO_TILE_METERS, destination, "_macro")
    metadata["notes"] = [
        "Original 1254-square generated color and separately generated structural height; 4096-square derived storage maps.",
        "Structural height is independent of diffuse mica/mineral coloration; optional microscopic grain is seeded and bounded.",
        "Height PNGs store unsigned 16-bit normalized linear data; the JSON ranges convert them into meters.",
        "Packed ORM is linear: ambient visibility R, roughness G, dielectric metallic zero B.",
        "PBR values are authored estimates, not measured scan channels or commercial reference assets.",
    ]
    (MATERIALS / f"{PREFIX}_bake.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    print(json.dumps(metadata, indent=2), flush=True)


if __name__ == "__main__":
    bake()
