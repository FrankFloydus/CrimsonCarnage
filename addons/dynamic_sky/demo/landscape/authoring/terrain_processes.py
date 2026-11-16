# Offline authored-scale landscape processes. Independent implementation of public
# stream-power / Priority-Flood concepts; not a calibrated geological simulation.
# References:
# https://doi.org/10.1016/j.geomorph.2012.10.008
# https://doi.org/10.1016/j.cageo.2013.04.024
# https://cs.purdue.edu/homes/bbenes/papers/Benes01SCCG.pdf
from collections import deque
import heapq
import time
import numpy as np

STREAM_POWER_STRENGTH = 0.35
STREAM_POWER_AREA_REFERENCE_M2 = 10000.0
STREAM_POWER_AREA_EXPONENT = 0.45
STREAM_POWER_REFERENCE_LENGTH_M = 6.0
REPOSE_DEGREES = 36.0
WEATHERING_METERS_PER_ITERATION = 0.24
MOBILE_RELAXATIONS_PER_ITERATION = 4
D8 = ((-1, 0), (1, 0), (0, -1), (0, 1),
      (-1, -1), (-1, 1), (1, -1), (1, 1))


def _bounded_neighbours(shape):
    rows, columns = shape
    indices = np.arange(rows * columns, dtype=np.int32).reshape(shape)
    neighbours = np.full((rows * columns, 8), -1, dtype=np.int32)
    pairs = []
    for direction, (dy, dx) in enumerate(D8):
        source = (slice(max(0, -dy), min(rows, rows - dy)),
                  slice(max(0, -dx), min(columns, columns - dx)))
        destination = (slice(max(0, dy), min(rows, rows + dy)),
                       slice(max(0, dx), min(columns, columns + dx)))
        neighbours[indices[source].ravel(), direction] = indices[destination].ravel()
        pairs.append((source, destination, float(np.hypot(dy, dx))))
    return neighbours, pairs


def _priority_flood(height, neighbours, outlets):
    # Filled levels are a ROUTING surface only. Actual terrain is not filled.
    # The FIFO handles already-enclosed depressions without repeated heap work.
    surface = np.asarray(height, dtype=np.float64).ravel().copy()
    visited = np.asarray(outlets, dtype=bool).ravel().copy()
    seeds = np.flatnonzero(visited)
    parent = np.arange(surface.size, dtype=np.int32)
    heap = list(zip(surface[seeds].tolist(), seeds.tolist()))
    heapq.heapify(heap)
    pit = deque()
    order = np.empty(surface.size, dtype=np.int32)
    cursor = 0
    while heap or pit:
        if pit:
            level, index = pit.popleft()
        else:
            level, index = heapq.heappop(heap)
        order[cursor] = index
        cursor += 1
        for raw_neighbour in neighbours[index]:
            neighbour = int(raw_neighbour)
            if neighbour < 0 or visited[neighbour]:
                continue
            visited[neighbour] = True
            parent[neighbour] = index
            original = surface[neighbour]
            if original <= level:
                surface[neighbour] = level
                pit.append((level, neighbour))
            else:
                heapq.heappush(heap, (float(original), neighbour))
    if cursor != surface.size:
        raise RuntimeError("Priority-Flood did not reach every cell")
    return surface, parent, order


def _flow_graph(height, neighbours, outlets, step):
    filled, receiver, order = _priority_flood(height, neighbours, outlets)
    safe_neighbours = np.maximum(neighbours, 0)
    distances = np.asarray([np.hypot(dy, dx) * step for dy, dx in D8])
    slopes = (filled[:, None] - filled[safe_neighbours]) / distances
    slopes[neighbours < 0] = -np.inf
    best = np.argmax(slopes, axis=1)
    greatest = slopes[np.arange(filled.size), best]
    descending = greatest > 1.0e-12
    receiver[descending] = neighbours[np.flatnonzero(descending), best[descending]]
    receiver[np.asarray(outlets).ravel()] = np.flatnonzero(np.asarray(outlets).ravel())
    # Every receiver precedes its donors, including flat depression paths.
    rank = np.empty(filled.size, dtype=np.int32)
    rank[order] = np.arange(filled.size, dtype=np.int32)
    active = receiver != np.arange(filled.size)
    if np.any(rank[receiver[active]] >= rank[active]):
        raise RuntimeError("Drainage graph contains a cyclic or unordered edge")
    area = np.full(filled.size, step * step, dtype=np.float64)
    for index in order[::-1]:
        target = receiver[index]
        if target != index:
            area[target] += area[index]
    width = height.shape[1]
    row = np.arange(filled.size) // width
    column = np.arange(filled.size) % width
    lengths = np.hypot(row - receiver // width, column - receiver % width) * step
    lengths[~active] = step
    return receiver, order, area, lengths, filled


def _steepest_surface_slope(height, pairs, step):
    slope = np.zeros_like(height)
    for source, destination, unit_distance in pairs:
        difference = np.maximum(height[source] - height[destination], 0.0)
        np.maximum(slope[source], difference / (step * unit_distance), out=slope[source])
    return slope


def _transport_mobile(bedrock, sediment, mask, pairs, step, sweeps=4):
    # Only loose sediment moves. Exchange never crosses an inactive/locked cell.
    before = float(np.sum(sediment, dtype=np.float64))
    repose = np.tan(np.deg2rad(REPOSE_DEGREES))
    for _ in range(sweeps):
        surface = bedrock + sediment
        total_excess = np.zeros_like(surface)
        greatest_excess = np.zeros_like(surface)
        excesses = []
        for source, destination, unit_distance in pairs:
            excess = np.maximum(surface[source] - surface[destination] -
                                repose * step * unit_distance, 0.0)
            exchange_mask = np.minimum(mask[source], mask[destination])
            excess *= exchange_mask
            excesses.append(excess)
            total_excess[source] += excess
            np.maximum(greatest_excess[source], excess, out=greatest_excess[source])
        movable = np.minimum(sediment, greatest_excess * 0.35)
        delta = np.zeros_like(sediment)
        for (source, destination, _), excess in zip(pairs, excesses):
            flux = movable[source] * np.divide(
                excess, total_excess[source], out=np.zeros_like(excess),
                where=total_excess[source] > 0.0)
            delta[source] -= flux
            delta[destination] += flux
        sediment += delta
        # At worst numerical cancellation produces sub-ulp negatives.
        if float(np.min(sediment)) < -1.0e-10:
            raise RuntimeError("Mobile sediment transport produced a negative layer")
        np.maximum(sediment, 0.0, out=sediment)
    return float(np.sum(sediment, dtype=np.float64)) - before


def breach_depressions(initial, step, mask, sinks, minimum_gradient=0.01, maximum_cut=100.0):
    # Intentional author-guided drainage topology editing, NOT an optimal breach.
    # The fixed Priority-Flood graph supplies paths; low donor levels propagate
    # downstream. Any positive mask permits a full channel cut. Zero locks cells.
    # Outer edges and explicit sinks retain their input base levels. No filling,
    # sediment production, or channel widening is hidden inside this operation.
    # The authored cut cap is per cell relative to initial, not per visited donor.
    started = time.perf_counter()
    original = np.array(initial, dtype=np.float64, copy=True)
    permission = np.asarray(mask, dtype=np.float64)
    sink_mask = np.asarray(sinks, dtype=bool)
    if original.ndim != 2 or min(original.shape) < 2:
        raise ValueError("initial must be a two-dimensional grid at least 2 by 2")
    if permission.shape != original.shape or sink_mask.shape != original.shape:
        raise ValueError("mask and sinks must match the height grid")
    if not np.all(np.isfinite(original)) or not np.all(np.isfinite(permission)):
        raise ValueError("height and mask must be finite")
    if np.any((permission < 0) | (permission > 1)):
        raise ValueError("mask must lie in [0,1]")
    if not np.isfinite(step) or step <= 0:
        raise ValueError("step must be positive and finite")
    if not np.isfinite(minimum_gradient) or minimum_gradient < 0:
        raise ValueError("minimum_gradient must be finite and nonnegative")
    if not np.isfinite(maximum_cut) or maximum_cut <= 0:
        raise ValueError("maximum_cut must be positive and finite")
    outlets = sink_mask.copy()
    outlets[0, :] = outlets[-1, :] = True
    outlets[:, 0] = outlets[:, -1] = True
    allowed = (permission > 0) & ~outlets
    neighbours, _ = _bounded_neighbours(original.shape)
    receiver, order, area, lengths, filled = _flow_graph(original, neighbours, outlets, step)
    height = original.ravel().copy()
    floor = original.ravel() - maximum_cut
    allowed_flat = allowed.ravel()
    locked_attempts = 0
    cap_attempts = 0
    cut_requests = 0
    for raw_index in order[::-1]:
        index = int(raw_index)
        target = int(receiver[index])
        if target == index:
            continue
        desired = height[index] - minimum_gradient * lengths[index]
        if height[target] <= desired + 1.0e-10:
            continue
        cut_requests += 1
        if not allowed_flat[target]:
            locked_attempts += 1
            continue
        if desired < floor[target]:
            cap_attempts += 1
        height[target] = min(height[target], max(desired, floor[target]))
    difference = height - height[receiver]
    routed = receiver != np.arange(height.size)
    blocked_edges = routed & (difference < minimum_gradient * lengths - 1.0e-8)
    blocked_locked = blocked_edges & ~allowed_flat[receiver]
    blocked_cap = blocked_edges & allowed_flat[receiver] & \
                  (height[receiver] <= floor[receiver] + 1.0e-8)
    route_blocked = np.zeros(height.size, dtype=bool)
    for raw_index in order:
        index = int(raw_index)
        target = int(receiver[index])
        if target != index:
            route_blocked[index] = blocked_edges[index] or route_blocked[target]
    result = height.reshape(original.shape)
    cuts = original - result
    if np.any(cuts < -1.0e-10) or np.any(cuts > maximum_cut + 1.0e-8):
        raise RuntimeError("Breach violated its lowering-only cut limits")
    if not np.array_equal(result[~allowed], original[~allowed]):
        raise RuntimeError("Breach changed a locked or fixed outlet cell")
    if not np.all(np.isfinite(result)):
        raise RuntimeError("Breach produced nonfinite heights")
    positive = cuts[cuts > 1.0e-8]
    diagnostics = {
        "operation": "author_guided_priority_flood_receiver_carving",
        "optimal_breach_claim": False,
        "routing_graph": "fixed acyclic Priority-Flood / steepest D8 graph from input",
        "mask_semantics": "zero locks; any positive value authorizes full capped channel cuts",
        "outlet_semantics": "explicit sinks and bounded outer edges retain input height",
        "channel_widening_performed": False,
        "silent_filling_performed": False,
        "shape": original.shape,
        "step_m": float(step),
        "minimum_gradient": float(minimum_gradient),
        "cut_cap_m": float(maximum_cut),
        "seconds": time.perf_counter() - started,
        "cut_requests": int(cut_requests),
        "cut_cells": int(positive.size),
        "maximum_cut_m": float(np.max(cuts)),
        "positive_cut_p50_p95_m": np.percentile(positive, [50,95]).tolist() if positive.size else [0.0,0.0],
        "excavated_volume_m3": float(np.sum(cuts)) * step * step,
        "maximum_locked_height_change_m": 0.0,
        "blocked_locked_attempts": int(locked_attempts),
        "blocked_cap_attempts": int(cap_attempts),
        "remaining_blocked_locked_edges": int(np.count_nonzero(blocked_locked)),
        "remaining_blocked_cut_cap_edges": int(np.count_nonzero(blocked_cap)),
        "remaining_blocked_edges": int(np.count_nonzero(blocked_edges)),
        "cells_with_blocked_outlet_route": int(np.count_nonzero(route_blocked)),
        "minimum_actual_gradient": float(np.min(difference[routed] / lengths[routed])) if np.any(routed) else 0.0,
        "maximum_original_virtual_fill_depth_m": float(np.max(filled - original.ravel())),
        "routing_order_violations": 0,
    }
    return result, diagnostics
