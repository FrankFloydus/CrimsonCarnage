"""Bake periodic, band-limited directional wave slopes for the demo lake."""

from pathlib import Path

import numpy as np
from PIL import Image


SIZE = 512
PERIOD_METERS = 36.0
OUTPUT = Path(__file__).with_name("lake_wave_slopes.png")


def wave_slopes(rng, wavelengths, weights, spread):
    frequency = 2.0 * np.pi * np.fft.fftfreq(SIZE, PERIOD_METERS / SIZE)
    wave_x, wave_z = np.meshgrid(frequency, frequency)
    wave_number = np.hypot(wave_x, wave_z)
    safe_number = np.maximum(wave_number, 1e-8)
    alignment = np.abs(wave_x) / safe_number
    direction = spread + (1.0 - spread) * alignment**2.6

    spectrum = np.zeros((SIZE, SIZE))
    for wavelength, weight in zip(wavelengths, weights):
        center = 2.0 * np.pi / wavelength
        spectrum += weight * np.exp(-0.5 * (np.log(safe_number / center) / 0.34) ** 2)
    height = np.fft.fft2(rng.standard_normal((SIZE, SIZE))) * np.sqrt(spectrum * direction) / safe_number
    height[0, 0] = 0.0
    slopes = np.stack(
        [np.fft.ifft2(height * (1j * wave_x)).real, np.fft.ifft2(height * (1j * wave_z)).real],
        axis=-1,
    )
    return slopes / (np.sqrt(np.mean(slopes**2)) * 4.0)


def bake():
    rng = np.random.default_rng(6413)
    gravity = wave_slopes(rng, [2.1, 3.8, 6.3], [0.65, 1.0, 0.63], 0.46)
    short = wave_slopes(rng, [0.21, 0.54, 1.2], [0.18, 0.8, 0.69], 0.21)
    fields = np.concatenate((gravity, short), axis=-1)
    encoded = np.round((np.clip(fields, -1.0, 1.0) * 0.5 + 0.5) * 255.0).astype(np.uint8)
    Image.fromarray(encoded).save(OUTPUT, optimize=True)


if __name__ == "__main__":
    bake()
