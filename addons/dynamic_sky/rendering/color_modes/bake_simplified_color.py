"""Bake original 3D sky color palettes into Godot-importable slice atlases.

Run this script with Python, NumPy, and Pillow after editing simplified_palette.json.
The atlas columns are signed-sqrt view elevation, the rows are relative azimuth
cosine, and the tile order is signed-sqrt light elevation. RGB uses gamma 2.2
encoding so the eight-bit texture preserves the dark end of the night palette.
"""

from pathlib import Path
import json

import numpy as np
from PIL import Image


FOLDER = Path(__file__).resolve().parent
SLICE_COLUMNS = 8
SLICE_ROWS = 4
SLICE_COUNT = SLICE_COLUMNS * SLICE_ROWS
GAMMA = 2.2


def smoothstep(low, high, value):
    fraction = np.clip((value - low) / (high - low), 0.0, 1.0)
    return fraction * fraction * (3.0 - 2.0 * fraction)


def mix(a, b, weight):
    return a + (b - a) * np.asarray(weight)[..., np.newaxis]


def linear_color(hex_color):
    rgb = np.array([int(hex_color[i:i + 2], 16) for i in (1, 3, 5)]) / 255.0
    return np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)


def axes(width, height):
    view_axis = np.linspace(-1.0, 1.0, width)[np.newaxis, np.newaxis, :]
    azimuth_cosine = np.linspace(-1.0, 1.0, height)[np.newaxis, :, np.newaxis]
    light_axis = np.linspace(-1.0, 1.0, SLICE_COUNT)[:, np.newaxis, np.newaxis]
    return view_axis * abs(view_axis), azimuth_cosine, light_axis * abs(light_axis)


def sun_volume(palette):
    view_y, azimuth_cosine, sun_y = axes(64, 32)
    colors = {name: linear_color(value) for name, value in palette.items()}
    sky_height = np.maximum(view_y, 0.0) ** 0.56
    ground_blend = smoothstep(0.0, 0.75, -view_y)
    day = mix(colors["day_horizon"], colors["day_zenith"], sky_height)
    day = mix(day, colors["day_ground"], ground_blend)
    night = mix(colors["night_horizon"], colors["night_zenith"], sky_height)
    night = mix(night, colors["night_ground"], ground_blend)
    day_weight = smoothstep(-0.10, 0.28, sun_y)
    twilight_weight = smoothstep(-0.24, -0.085, sun_y) * (1.0 - smoothstep(0.02, 0.25, sun_y))

    # A broad warm horizon follows the sun and leaves the opposite horizon cool.
    toward_sun = smoothstep(-0.24, 0.94, azimuth_cosine) ** 1.55
    evening_horizon = mix(colors["twilight_antisolar"], colors["twilight_horizon"], toward_sun)
    evening_horizon = mix(evening_horizon, colors["twilight_solar"], toward_sun ** 3.0 * 0.36)
    evening = mix(evening_horizon, colors["twilight_zenith"], sky_height)
    evening = mix(evening, colors["twilight_ground"], ground_blend)
    return mix(mix(night, day, day_weight), evening, twilight_weight * 0.91)


def moon_volume(palette):
    view_y, azimuth_cosine, moon_y = axes(48, 24)
    sky_tint = linear_color(palette["scattered_light"])
    horizon_tint = linear_color(palette["horizon_scatter"])
    horizontal = np.sqrt(np.maximum(0.0, 1.0 - view_y ** 2) * np.maximum(0.0, 1.0 - moon_y ** 2))
    alignment = np.maximum(0.0, view_y * moon_y + horizontal * azimuth_cosine)
    horizon_weight = 1.0 - smoothstep(0.0, 0.36, abs(view_y))
    tint = mix(sky_tint, horizon_tint, horizon_weight * 0.62)
    halo = alignment ** 8 * 0.35 + alignment ** 38 * 0.65
    moon_height = smoothstep(-0.035, 0.31, moon_y)
    lower_fade = 1.0 - smoothstep(0.0, 0.58, -view_y)
    intensity = (palette["sky_strength"] + palette["halo_strength"] * halo) * moon_height * lower_fade
    return tint * intensity[..., np.newaxis]


def write_atlas(filename, volume):
    slices, height, width, channels = volume.shape
    if slices != SLICE_COUNT or channels != 3:
        raise ValueError("Unexpected sky color volume dimensions")
    encoded = np.rint(np.clip(volume, 0.0, 1.0) ** (1.0 / GAMMA) * 255.0).astype(np.uint8)
    atlas = np.empty((height * SLICE_ROWS, width * SLICE_COLUMNS, 3), dtype=np.uint8)
    for index, layer in enumerate(encoded):
        column = index % SLICE_COLUMNS
        row = index // SLICE_COLUMNS
        atlas[row * height:(row + 1) * height, column * width:(column + 1) * width] = layer
    Image.fromarray(atlas).save(FOLDER / filename, optimize=True)


def main():
    palette = json.loads((FOLDER / "simplified_palette.json").read_text(encoding="utf-8"))
    write_atlas("simple_sun_color.png", sun_volume(palette["sun"]))
    write_atlas("simple_moon_color.png", moon_volume(palette["moon"]))


if __name__ == "__main__":
    main()
