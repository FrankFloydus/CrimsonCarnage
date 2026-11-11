"""Bake the original atmosphere lookup tables and seamless cloud noise.

Run with Python, NumPy, SciPy and Pillow. The renderer uses these images as
linear data. The atlas tiles are ordered left to right, then top to bottom.
"""

from itertools import product
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates


OUTPUT = Path(__file__).resolve().parents[1]
PLANET_RADIUS = 6371.0
ATMOSPHERE_TOP = 100.0
RAYLEIGH = np.array([0.005802, 0.013558, 0.033100])
MIE_EXTINCTION = 0.0044
MIE_SCATTERING = 0.00396
OZONE = np.array([0.000650, 0.001881, 0.000085])


def texture_atlas(volume, columns):
    depth, height, width, channels = volume.shape
    rows = depth // columns
    return volume.reshape(rows, columns, height, width, channels).transpose(0, 2, 1, 3, 4).reshape(
        rows * height, columns * width, channels
    )


def save_data(filename, values):
    pixels = np.rint(np.clip(values, 0.0, 1.0) * 255.0).astype(np.uint8)
    Image.fromarray(pixels).save(OUTPUT / filename, optimize=True)


def grid(size, dimensions, frequency):
    points = np.indices((size,) * dimensions, dtype=np.float32) * (frequency / size)
    base = np.floor(points).astype(np.int32)
    return base, points - base


def gradient_noise(size, dimensions, frequency, random):
    gradients = random.normal(size=(frequency,) * dimensions + (dimensions,)).astype(np.float32)
    gradients /= np.maximum(np.linalg.norm(gradients, axis=-1, keepdims=True), 1e-5)
    base, fraction = grid(size, dimensions, frequency)
    blend = fraction**3 * (fraction * (fraction * 6.0 - 15.0) + 10.0)
    result = np.zeros_like(fraction[0])
    for corner in product((0, 1), repeat=dimensions):
        offset = np.array(corner).reshape((dimensions,) + (1,) * dimensions)
        lattice = tuple((base + offset) % frequency)
        direction = gradients[lattice]
        delta = np.moveaxis(fraction - offset, 0, -1)
        weight = np.prod(np.where(offset == 1, blend, 1.0 - blend), axis=0)
        result += weight * np.sum(direction * delta, axis=-1)
    return np.clip(result * 0.95 + 0.5, 0.0, 1.0)


def cellular_noise(size, dimensions, frequency, random):
    jitter = random.uniform(0.08, 0.92, (frequency,) * dimensions + (dimensions,)).astype(np.float32)
    base, fraction = grid(size, dimensions, frequency)
    nearest = np.full_like(fraction[0], 4.0)
    for neighbor in product((-1, 0, 1), repeat=dimensions):
        offset = np.array(neighbor).reshape((dimensions,) + (1,) * dimensions)
        lattice = tuple((base + offset) % frequency)
        delta = np.moveaxis(fraction - offset, 0, -1) - jitter[lattice]
        nearest = np.minimum(nearest, np.sum(delta * delta, axis=-1))
    return 1.0 - np.clip(np.sqrt(nearest), 0.0, 1.0)


def bake_clouds():
    random = np.random.default_rng(864230)
    cells = [cellular_noise(64, 3, frequency, random) for frequency in (4, 8, 16, 24)]
    gradient = (
        0.66 * gradient_noise(64, 3, 5, random)
        + 0.24 * gradient_noise(64, 3, 10, random)
        + 0.10 * gradient_noise(64, 3, 20, random)
    )
    worley = 0.64 * cells[0] + 0.26 * cells[1] + 0.10 * cells[2]
    shape = gradient * (1.0 - worley) + worley
    detail = 0.60 * cells[1] + 0.27 * cells[2] + 0.13 * cells[3]
    erosion = 0.70 * cells[2] + 0.30 * cells[3]
    save_data("cloud_noise.png", texture_atlas(np.stack([shape, detail, erosion], axis=-1), 8))

    wide = gradient_noise(256, 2, 9, random)
    medium = gradient_noise(256, 2, 20, random)
    narrow = gradient_noise(256, 2, 43, random)
    coverage = np.clip(0.50 + (0.64 * wide + 0.26 * medium + 0.10 * narrow - 0.50) * 2.05, 0.0, 1.0)
    cloud_type = gradient_noise(256, 2, 12, random)
    wisps = 0.62 * gradient_noise(256, 2, 25, random) + 0.38 * narrow
    save_data("cloud_weather.png", np.stack([coverage, cloud_type, wisps], axis=-1))


def atmosphere_density(altitude):
    altitude = np.maximum(altitude, 0.0)
    return np.stack([
        np.exp(-altitude / 8.0),
        np.exp(-altitude / 1.2),
        np.maximum(1.0 - np.abs(altitude - 25.0) / 15.0, 0.0),
    ], axis=-1)


def distance_to_space(height, cosine):
    radius = PLANET_RADIUS + height
    radial = radius * cosine
    return np.sqrt(radial * radial + (ATMOSPHERE_TOP - height) * (2.0 * PLANET_RADIUS + ATMOSPHERE_TOP + height)) - radial


def radius_along_ray(height, cosine, distance):
    radius = PLANET_RADIUS + height
    return np.sqrt(radius * radius + distance * distance + 2.0 * radius * cosine * distance)


def bake_transmittance():
    heights = ATMOSPHERE_TOP * np.linspace(0.0, 1.0, 96)[:, None] ** 2
    parameter = np.linspace(-0.5, 1.0, 192)[None, :]
    cosines = parameter * np.abs(parameter)
    edges = np.linspace(0.0, 1.0, 145) ** 2 * distance_to_space(heights, cosines)[..., None]
    lengths = np.diff(edges, axis=-1)
    centers = (edges[..., 1:] + edges[..., :-1]) * 0.5
    sample_height = radius_along_ray(heights[..., None], cosines[..., None], centers) - PLANET_RADIUS
    density = atmosphere_density(sample_height)
    optical_depth = np.sum(density * lengths[..., None], axis=-2)
    extinction = np.stack([RAYLEIGH, np.full(3, MIE_EXTINCTION), OZONE])
    transmission = np.exp(-(optical_depth @ extinction))
    ground_horizon = -np.sqrt(1.0 - (PLANET_RADIUS / (PLANET_RADIUS + heights)) ** 2)
    transmission = np.where((cosines < ground_horizon)[..., None], 0.0, transmission)
    save_data("atmosphere_transmittance.png", transmission ** (1.0 / 2.2))
    return transmission


def sample_transmittance(transmission, height, cosine):
    row = np.sqrt(np.clip(height / ATMOSPHERE_TOP, 0.0, 1.0)) * (transmission.shape[0] - 1)
    signed_root = np.sign(cosine) * np.sqrt(np.abs(cosine))
    column = np.clip((signed_root + 0.5) / 1.5, 0.0, 1.0) * (transmission.shape[1] - 1)
    coordinates = np.broadcast_arrays(row, column)
    return np.stack(
        [map_coordinates(transmission[..., channel], coordinates, order=1, mode="nearest") for channel in range(3)],
        axis=-1,
    )


def bake_sky_view(transmission):
    # The atlas samples relative azimuth, observer elevation, and solar elevation.
    azimuth = np.linspace(0.0, np.pi, 128)[None, :, None]
    view_cos = np.linspace(0.0, 1.0, 80)[:, None, None] ** 2
    solar_parameter = np.linspace(-0.6, 1.0, 64)
    sun_cosines = solar_parameter * np.abs(solar_parameter)
    edges = np.linspace(0.0, 1.0, 41) ** 2 * distance_to_space(0.0, view_cos)
    lengths = np.diff(edges, axis=-1)
    centers = (edges[..., 1:] + edges[..., :-1]) * 0.5
    radius = radius_along_ray(0.0, view_cos, centers)
    altitude = radius - PLANET_RADIUS
    density = atmosphere_density(altitude)
    extinction = density @ np.stack([RAYLEIGH, np.full(3, MIE_EXTINCTION), OZONE])
    segment_depth = lengths[..., None] * extinction
    view_depth = np.cumsum(segment_depth, axis=-2) - segment_depth * 0.5
    view_transmittance = np.exp(-view_depth)
    rayleigh_scattering = density[..., 0, None] * RAYLEIGH
    mie_scattering = density[..., 1, None] * MIE_SCATTERING
    slice_images = []
    for solar_cos in sun_cosines:
        view_sun_cos = view_cos * solar_cos + np.sqrt((1.0 - view_cos * view_cos) * (1.0 - solar_cos * solar_cos)) * np.cos(azimuth)
        light_cos = (PLANET_RADIUS * solar_cos + centers * view_sun_cos) / radius
        light_transmission = sample_transmittance(transmission, altitude, light_cos)
        rayleigh_phase = (3.0 / (16.0 * np.pi)) * (1.0 + view_sun_cos * view_sun_cos)
        eccentricity = 0.76
        mie_phase = (1.0 - eccentricity**2) / (4.0 * np.pi * (1.0 + eccentricity**2 - 2.0 * eccentricity * view_sun_cos) ** 1.5)
        source = light_transmission * (rayleigh_scattering * rayleigh_phase[..., None] + mie_scattering * mie_phase[..., None])
        # Low-frequency fill approximates light scattered more than once.
        fill = np.clip((solar_cos + 0.18) / 0.65, 0.0, 1.0)
        source += (rayleigh_scattering + mie_scattering) * fill * np.array([0.012, 0.020, 0.036])
        luminance = np.sum(view_transmittance * source * lengths[..., None], axis=-2) * 15.0
        slice_images.append(np.log1p(luminance * 24.0) / np.log(97.0))
    save_data("atmosphere_view.png", texture_atlas(np.stack(slice_images), 8))


if __name__ == "__main__":
    bake_clouds()
    bake_sky_view(bake_transmittance())
