"""Derive editable 4K material data from the original 1254px ImageGen rock source.

The source is diffuse artwork, not a scan. Height, AO and roughness are conservative
authored estimates; the outcrop mesh supplies its actual large fracture geometry.
"""

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


DETAIL_TILE_METERS = 6.0
MACRO_TILE_METERS = 18.0


def write_orm(height, meters_per_texel, grain, joints, destination):
    orm = np.empty((SIZE, SIZE, 3), dtype=np.uint8)
    orm[:, :, 0] = byte_image(ambient_visibility(height, meters_per_texel, 0.60))
    orm[:, :, 1] = byte_image(np.clip(0.84 + grain * 0.06 - joints * 0.035, 0.68, 0.96))
    orm[:, :, 2] = 0
    save_webp(orm, destination)


def bake():
    destination = MATERIALS / "pbr"
    colors = albedo_master(MATERIALS / "masters/ridge_gneiss.png")
    save_webp(colors, destination / "ridge_gneiss_albedo.webp")
    rgb = colors.astype(np.float32) / 255.0
    del colors
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    luminance = np.log(np.maximum(linear @ np.array([0.2126, 0.7152, 0.0722]), 0.015)).astype(np.float32)
    del rgb, linear

    minerals = ndimage.gaussian_filter(luminance, 2.5, mode="wrap")
    chips = ndimage.gaussian_filter(luminance, 14.0, mode="wrap")
    planes = ndimage.gaussian_filter(luminance, 70.0, mode="wrap")
    broad = ndimage.gaussian_filter(luminance, 240.0, mode="wrap")
    grain = normalized_band(luminance - minerals, 3.0)
    chip_relief = normalized_band(minerals - chips, 3.0)
    joints = normalized_band(chips - planes, 3.0)
    detail_height = grain * 0.0012 + chip_relief * 0.0045 + joints * 0.014
    meters_per_texel = DETAIL_TILE_METERS / SIZE
    save_webp(tangent_normals(detail_height, meters_per_texel), destination / "ridge_gneiss_normal.webp")
    write_orm(detail_height, meters_per_texel, grain, joints, destination / "ridge_gneiss_orm.webp")

    geological_planes = normalized_band(planes - broad, 3.0)
    macro_height = geological_planes * 0.12 + joints * 0.045
    meters_per_texel = MACRO_TILE_METERS / SIZE
    save_webp(tangent_normals(macro_height, meters_per_texel), destination / "ridge_gneiss_macro_normal.webp")
    write_orm(macro_height, meters_per_texel, joints, geological_planes, destination / "ridge_gneiss_macro_orm.webp")
    print(f"Ridge gneiss: {SIZE} square derived maps; 1254 square original source; 6m detail / 18m macro", flush=True)


if __name__ == "__main__":
    bake()
