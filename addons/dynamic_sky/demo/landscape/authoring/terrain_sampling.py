"""Sample the exact triangle split used by the authored valley mesh."""

import numpy as np


def sample_ground(field, x, z):
    xs = field["xs"]
    zs = field["zs"]
    heights = field["height"]
    x = np.asarray(x)
    z = np.asarray(z)
    column = np.clip(np.searchsorted(xs, x, side="right") - 1, 0, len(xs) - 2)
    row = np.clip(np.searchsorted(zs, z, side="right") - 1, 0, len(zs) - 2)
    u = np.clip((x - xs[column]) / (xs[column + 1] - xs[column]), 0.0, 1.0)
    v = np.clip((z - zs[row]) / (zs[row + 1] - zs[row]), 0.0, 1.0)
    low_left = heights[row, column]
    low_right = heights[row, column + 1]
    high_left = heights[row + 1, column]
    high_right = heights[row + 1, column + 1]
    lower = low_left + (low_right - low_left) * u + (high_left - low_left) * v
    upper = high_right + (high_left - high_right) * (1.0 - u) + (low_right - high_right) * (1.0 - v)
    return np.where(u + v <= 1.0, lower, upper)
