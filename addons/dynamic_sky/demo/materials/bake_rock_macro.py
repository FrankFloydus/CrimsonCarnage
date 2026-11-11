"""Bake geological-scale rock normals and ORM from the original ImageGen master."""

import numpy as np
from scipy import ndimage

from bake_materials import (
    MATERIALS,
    SIZE,
    albedo_master,
    ambient_visibility,
    byte_image,
    normalized_band,
    save_webp,
    tangent_normals,
)


TILE_METERS = 32.0
RELIEF_METERS = 0.42


def bake():
    colors = albedo_master(MATERIALS / "masters/alpine_rock.png").astype(np.float32) / 255.0
    linear = np.where(colors <= 0.04045, colors / 12.92, ((colors + 0.055) / 1.055) ** 2.4)
    luminance = np.log(np.maximum(linear @ np.array([0.2126, 0.7152, 0.0722]), 0.015))
    fine_shelves = ndimage.gaussian_filter(luminance, 8.0, mode="wrap")
    middle_shelves = ndimage.gaussian_filter(luminance, 48.0, mode="wrap")
    broad_shelves = ndimage.gaussian_filter(luminance, 256.0, mode="wrap")
    bedding = normalized_band(middle_shelves - broad_shelves, 3.0)
    fracture = normalized_band(fine_shelves - middle_shelves, 3.0)
    relief = (bedding * 0.80 + fracture * 0.20) * RELIEF_METERS
    meters_per_texel = TILE_METERS / SIZE
    destination = MATERIALS / "pbr"
    save_webp(tangent_normals(relief, meters_per_texel), destination / "alpine_rock_macro_normal.webp")

    orm = np.empty((SIZE, SIZE, 3), dtype=np.uint8)
    orm[:, :, 0] = byte_image(ambient_visibility(relief, meters_per_texel, 0.62))
    orm[:, :, 1] = byte_image(np.clip(0.77 + bedding * 0.10 - fracture * 0.04, 0.52, 0.93))
    orm[:, :, 2] = 0
    save_webp(orm, destination / "alpine_rock_macro_orm.webp")
    print(f"Rock macro normal and ORM: {SIZE}x{SIZE}, {TILE_METERS:g} m tile, {RELIEF_METERS:g} m relief")


if __name__ == "__main__":
    bake()
