"""Bake directional lighting data from the original grayscale ImageGen cloud dome."""

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "static_cloud_dome_map.png"
OUTPUT = ROOT / "static_cloud_dome_lighting.png"


def normalized(image):
    return np.asarray(image, dtype=np.float32) / 255.0


def smoothstep(low, high, values):
    weight = np.clip((values - low) / (high - low), 0.0, 1.0)
    return weight * weight * (3.0 - 2.0 * weight)


def sample_offset(image, offset_x, offset_y):
    shifted = image.transform(
        image.size,
        Image.Transform.AFFINE,
        (1.0, 0.0, offset_x, 0.0, 1.0, offset_y),
        Image.Resampling.BILINEAR,
        fillcolor=0,
    )
    return normalized(shifted)


def main():
    with Image.open(SOURCE) as source:
        density = source.convert("L")

    scale = density.width / 1254.0
    detail = density.filter(ImageFilter.GaussianBlur(2.2 * scale))
    broad = density.filter(ImageFilter.GaussianBlur(9.0 * scale))
    mass = normalized(density)
    relief = 0.65 * normalized(detail) + 0.35 * normalized(broad)
    alpha = smoothstep(0.032, 0.48, np.maximum(mass, normalized(detail) * 0.91))
    base_light = 0.20 + 0.57 * np.power(np.clip(mass, 0.0, 1.0), 0.72)

    channels = []
    for index in range(3):
        # The shader uses map-space +U as azimuth zero and +V as a positive angle.
        angle = math.tau * index / 3.0
        x = math.cos(angle) * scale
        y = math.sin(angle) * scale
        near = sample_offset(detail, x * 10.0, y * 10.0)
        far = sample_offset(broad, x * 26.0, y * 26.0)
        facing = relief - (near * 0.65 + far * 0.35)
        lighting = np.clip(base_light + facing * 1.7, 0.055, 1.0)
        channels.append(lighting * smoothstep(0.0, 0.065, alpha))

    pixels = np.rint(np.stack([*channels, alpha], axis=-1) * 255.0).astype(np.uint8)
    temporary = OUTPUT.with_suffix(".png.tmp")
    Image.fromarray(pixels, "RGBA").save(temporary, format="PNG", optimize=True)
    temporary.replace(OUTPUT)


if __name__ == "__main__":
    main()
