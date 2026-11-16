# Multiple-flow-direction erosion with gravitational rock failure and a separate conservative mobile layer.
# This is an authored-scale landscape model, not calibrated geological time.
# Public stream-power and Priority-Flood references are in terrain_processes.py.
import time
import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.linalg import spsolve_triangular
from terrain_processes import (
    D8, STREAM_POWER_STRENGTH, STREAM_POWER_AREA_REFERENCE_M2,
    STREAM_POWER_AREA_EXPONENT, STREAM_POWER_REFERENCE_LENGTH_M,
    WEATHERING_METERS_PER_ITERATION, MOBILE_RELAXATIONS_PER_ITERATION,
    _bounded_neighbours, _priority_flood, _steepest_surface_slope, _transport_mobile,
)

MFD_SLOPE_EXPONENT = 1.1


def _triangular_edge_solve(receivers, coefficients, order, rank, rhs, area=False):
    count = len(order)
    present = coefficients > 0.0
    donors = np.broadcast_to(np.arange(count)[:, None], receivers.shape)[present]
    targets = receivers[present]
    values = -coefficients[present]
    if area:
        rows, columns = rank[targets], rank[donors]
        diagonal = np.ones(count)
    else:
        rows, columns = rank[donors], rank[targets]
        diagonal = 1.0 + np.sum(coefficients, axis=1)[order]
    # Receiver ranks are strictly lower than donor ranks, so this matrix is triangular.
    diagonal_indices = np.arange(count)
    matrix = coo_matrix((np.concatenate([values, diagonal]),
                         (np.concatenate([rows, diagonal_indices]),
                          np.concatenate([columns, diagonal_indices]))),
                        shape=(count, count)).tocsr()
    ordered = spsolve_triangular(matrix, rhs[order], lower=not area,
                                unit_diagonal=area)
    result = np.empty(count, dtype=np.float64)
    result[order] = ordered
    return result


def _mfd_flow_graph(height, neighbours, outlets, step):
    filled, parent, order = _priority_flood(height, neighbours, outlets)
    count = height.size
    rank = np.empty(count, dtype=np.int32)
    rank[order] = np.arange(count, dtype=np.int32)
    targets = np.maximum(neighbours, 0)
    distances = step * np.asarray([np.hypot(dy, dx) for dy, dx in D8])
    slopes = (filled[:, None] - filled[targets]) / distances
    eligible = (neighbours >= 0) & (rank[targets] < rank[:, None]) & (slopes > 1.0e-12)
    weights = np.where(eligible, np.maximum(slopes, 0.0), 0.0) ** MFD_SLOPE_EXPONENT
    totals = weights.sum(axis=1)
    np.divide(weights, totals[:, None], out=weights, where=totals[:, None] > 0.0)
    outlet_flat = outlets.ravel()
    flat = (totals == 0.0) & ~outlet_flat
    if np.any(flat):
        rows = np.flatnonzero(flat)
        matches = neighbours[rows] == parent[rows, None]
        if not np.all(matches.any(axis=1)):
            raise RuntimeError("Flat fallback parent is not a bounded D8 neighbour")
        weights[rows, np.argmax(matches, axis=1)] = 1.0
    weights[outlet_flat, :] = 0.0
    active_edges = weights > 0.0
    if np.any(rank[targets[active_edges]] >=
              np.broadcast_to(rank[:, None], targets.shape)[active_edges]):
        raise RuntimeError("MFD edge violates the Priority-Flood DAG order")
    area = _triangular_edge_solve(targets, weights, order, rank,
                                  np.full(count, step * step), area=True)
    nonoutlet = ~outlet_flat
    row_error = float(np.max(abs(weights.sum(axis=1)[nonoutlet] - 1.0))) if np.any(nonoutlet) else 0.0
    outlet_error = float(np.sum(area[outlet_flat]) - count * step * step)
    if row_error > 1.0e-12 or abs(outlet_error) > max(count * step * step, 1.0) * 1.0e-10:
        raise RuntimeError("MFD contributing area is not conserved")
    stats = {
        "maximum_weight_row_sum_error": row_error,
        "outlet_area_accounting_error_m2": outlet_error,
        "split_flow_cells": int(np.count_nonzero(np.sum(active_edges, axis=1) > 1)),
        "nonoutlet_cells": int(np.count_nonzero(nonoutlet)),
        "mean_receivers_per_nonoutlet": float(np.mean(np.sum(active_edges, axis=1)[nonoutlet])) if np.any(nonoutlet) else 0.0,
        "flat_fallback_cells": int(np.count_nonzero(flat)),
        "maximum_drainage_area_m2": float(np.max(area)),
        "routing_order_violations": 0,
    }
    return targets, weights, order, rank, area, distances, filled, stats


def _implicit_mfd_surface(height, targets, weights, order, rank, area, distances, mask):
    old = height.ravel()
    factor = STREAM_POWER_STRENGTH * (area / STREAM_POWER_AREA_REFERENCE_M2) ** STREAM_POWER_AREA_EXPONENT
    coefficients = weights * factor[:, None] * (STREAM_POWER_REFERENCE_LENGTH_M / distances) * mask.ravel()[:, None]
    # Virtual spill routing can point uphill in physical terrain; it contributes
    # catchment area, but never an uphill incision force.
    initial_uphill = (old[targets] > old[:, None] + 1.0e-10) & (coefficients > 0.0)
    coefficients[initial_uphill] = 0.0
    pruned = 0
    solves = 0
    while True:
        if np.any(coefficients > 0.0):
            result = _triangular_edge_solve(targets, coefficients, order, rank, old)
            solves += 1
        else:
            result = old.copy()
        # Remove any receiver that would be uphill after the implicit update.
        # The remaining active edges then obey the same n=1 summed equation.
        invalid = (result[targets] > result[:, None] + 1.0e-9) & (coefficients > 0.0)
        if not np.any(invalid):
            break
        removed = int(np.count_nonzero(invalid))
        pruned += removed
        coefficients[invalid] = 0.0
        if solves > 64:
            raise RuntimeError("MFD implicit active-set pruning failed to converge")
    result = np.minimum(result, old)
    stats = {
        "initial_uphill_erosion_edges_skipped": int(np.count_nonzero(initial_uphill)),
        "postsolve_uphill_erosion_edges_pruned": pruned,
        "remaining_uphill_erosion_edges": 0,
        "implicit_triangular_solves": solves,
    }
    return result.reshape(height.shape), stats


def _rock_failure(bedrock,sediment,mask,pairs,step,critical_degrees,rate=.38):
    surface=bedrock+sediment
    critical=np.tan(np.deg2rad(critical_degrees))
    unsupported=np.zeros_like(surface)
    for source,destination,distance in pairs:
        excess=np.maximum(surface[source]-surface[destination]-critical[source]*step*distance,0)
        np.maximum(unsupported[source],excess,out=unsupported[source])
    release=np.minimum(unsupported*rate,15.0)*mask
    bedrock-=release
    sediment+=release
    return float(release.sum())


def erode_bedrock(initial: np.ndarray, step: float, process_mask: np.ndarray,
                   sinks: np.ndarray, iterations: int = 16, rock_slope_degrees=45.0):
    started = time.perf_counter()
    original = np.array(initial, dtype=np.float64, copy=True)
    mask = np.array(process_mask, dtype=np.float64, copy=True)
    sink_mask = np.asarray(sinks, dtype=bool)
    if original.ndim != 2 or min(original.shape) < 2:
        raise ValueError("initial must be a two-dimensional grid at least 2 by 2")
    if mask.shape != original.shape or sink_mask.shape != original.shape:
        raise ValueError("process_mask and sinks must match the height grid")
    if not np.all(np.isfinite(original)) or not np.all(np.isfinite(mask)):
        raise ValueError("height and process_mask must be finite")
    if np.any((mask < 0.0) | (mask > 1.0)):
        raise ValueError("process_mask must lie in [0,1]")
    if not np.isfinite(step) or step <= 0.0:
        raise ValueError("step must be positive and finite")
    if not isinstance(iterations, (int, np.integer)) or iterations < 0:
        raise ValueError("iterations must be a nonnegative integer")
    outlets = sink_mask.copy()
    outlets[0, :] = outlets[-1, :] = True
    outlets[:, 0] = outlets[:, -1] = True
    mask[outlets] = 0.0
    locked = mask <= 0.0
    critical_degrees=np.broadcast_to(np.asarray(rock_slope_degrees,dtype=float),original.shape).copy()
    if not np.all(np.isfinite(critical_degrees)) or np.any((critical_degrees<20)|(critical_degrees>80)):
        raise ValueError("rock_slope_degrees must be finite and lie in [20,80]")
    bedrock = original.copy()
    sediment = np.zeros_like(original)
    neighbours, pairs = _bounded_neighbours(original.shape)
    cell_area = step * step
    fluvial_export = sediment_export = weathered_volume = transport_error = 0.0
    maximum_row_error = maximum_area_error = 0.0
    uphill_skipped = uphill_pruned = triangular_solves = 0
    history = []
    failed_volume=0.0
    for iteration in range(iterations):
        height = bedrock + sediment
        targets, weights, order, rank, area, distances, filled, routing_stats = _mfd_flow_graph(
            height, neighbours, outlets, step)
        evolved, implicit_stats = _implicit_mfd_surface(
            height, targets, weights, order, rank, area, distances, mask)
        incision = np.maximum(height - evolved, 0.0)
        removed_sediment = np.minimum(sediment, incision)
        sediment -= removed_sediment
        bedrock -= incision - removed_sediment
        fluvial_export += float(np.sum(incision)) * cell_area
        sediment_export += float(np.sum(removed_sediment)) * cell_area
        slope = _steepest_surface_slope(bedrock + sediment, pairs, step)
        steepness = np.clip((slope - np.tan(np.deg2rad(52.0))) /
                            (np.tan(np.deg2rad(78.0)) - np.tan(np.deg2rad(52.0))), 0.0, 1.0)
        weathered = WEATHERING_METERS_PER_ITERATION * mask * steepness
        bedrock -= weathered
        sediment += weathered
        weathered_volume += float(np.sum(weathered)) * cell_area
        released=_rock_failure(bedrock,sediment,mask,pairs,step,critical_degrees)*cell_area
        failed_volume+=released
        weathered_volume+=released
        transport_error += _transport_mobile(bedrock, sediment, mask, pairs, step,
                                              max(MOBILE_RELAXATIONS_PER_ITERATION,8)) * cell_area
        bedrock[locked] = original[locked]
        sediment[locked] = 0.0
        maximum_row_error = max(maximum_row_error, routing_stats["maximum_weight_row_sum_error"])
        maximum_area_error = max(maximum_area_error, abs(routing_stats["outlet_area_accounting_error_m2"]))
        uphill_skipped += implicit_stats["initial_uphill_erosion_edges_skipped"]
        uphill_pruned += implicit_stats["postsolve_uphill_erosion_edges_pruned"]
        triangular_solves += implicit_stats["implicit_triangular_solves"]
        history.append({"iteration": iteration + 1,
                        "maximum_incision_m": float(np.max(original - bedrock - sediment)),
                        "split_flow_cells": routing_stats["split_flow_cells"],
                        "implicit_solves": implicit_stats["implicit_triangular_solves"]})
    for settling in range(32 if iterations else 0):
        released=_rock_failure(bedrock,sediment,mask,pairs,step,critical_degrees)*cell_area
        failed_volume+=released;weathered_volume+=released
        transport_error+=_transport_mobile(bedrock,sediment,mask,pairs,step,8)*cell_area
        bedrock[locked]=original[locked];sediment[locked]=0.0
    height = bedrock + sediment
    targets, weights, order, rank, area, distances, filled, routing_stats = _mfd_flow_graph(
        height, neighbours, outlets, step)
    drainage = np.clip(np.log1p(np.maximum(area - 1800.0, 0.0) / 1800.0) /
                       np.log1p(100.0), 0.0, 1.0).reshape(original.shape)
    active = mask > 0.0
    incision = original - height
    current_sediment = float(np.sum(sediment)) * cell_area
    total_change = float(np.sum(original - height)) * cell_area
    pit_depth = filled.reshape(original.shape) - height
    diagnostics = {
        "method": "MFD positive-downhill slope^1.1 weights on Priority-Flood DAG",
        "d_infinity_claim": False,
        "bedrock_failure": "material-dependent critical slope converts rock into mobile sediment; conservative repose transport",
        "failed_rock_volume_m3": failed_volume,
        "critical_rock_slope_range_degrees": [float(critical_degrees.min()),float(critical_degrees.max())],
        "implicit_method": "n=1 summed multi-receiver solve; uphill erosion edges excluded/pruned",
        "shape": original.shape, "step_m": float(step), "iterations": int(iterations),
        "seconds": time.perf_counter() - started,
        "maximum_incision_m": float(np.max(incision)),
        "p95_active_incision_m": float(np.percentile(np.maximum(incision[active], 0), 95)) if np.any(active) else 0.0,
        "maximum_deposition_m": max(float(np.max(-incision)), 0.0),
        "routing_depression_cells": int(np.count_nonzero(pit_depth > 1.0e-8)),
        "maximum_virtual_fill_depth_m": float(np.max(pit_depth)),
        "fluvial_export_volume_m3": fluvial_export,
        "mobile_export_volume_m3": sediment_export,
        "weathered_to_mobile_volume_m3": weathered_volume,
        "remaining_mobile_volume_m3": current_sediment,
        "mobile_transport_mass_error_m3": transport_error,
        "mobile_accounting_error_m3": current_sediment + sediment_export - weathered_volume,
        "total_mass_accounting_error_m3": total_change - fluvial_export,
        "maximum_locked_height_change_m": float(np.max(abs(height[locked] - original[locked]))) if np.any(locked) else 0.0,
        "maximum_weight_row_sum_error_all_iterations": maximum_row_error,
        "maximum_outlet_area_error_all_iterations_m2": maximum_area_error,
        "initial_uphill_erosion_edges_skipped_total": uphill_skipped,
        "postsolve_uphill_erosion_edges_pruned_total": uphill_pruned,
        "remaining_uphill_erosion_edges": 0,
        "implicit_triangular_solves_total": triangular_solves,
        "final_routing": routing_stats,
        "history": history,
    }
    if not np.all(np.isfinite(height)) or not np.all(np.isfinite(sediment)) or np.min(sediment) < 0:
        raise RuntimeError("MFD terrain evolution violated finite/nonnegative outputs")
    return height, sediment, drainage, diagnostics
