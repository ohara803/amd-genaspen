#!/usr/bin/env python3
"""Fit Type0 power coefficients and evaluate power/energy on runtime-grid data."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from run_type0_analysis import (
    add_static_features,
    build_machine_model,
    fit_power,
    power_from_features,
    write_csv,
    write_json,
)
from run_type0_runtime_grid import KERNELS, TARGET_SIZES, TRAIN_SIZES


NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_measurements(path: Path, wavefront_size: int) -> list[dict]:
    run_pattern = re.compile(
        r"^\[RUN\] (axpy|copy|dot) (train|target) n=(\d+) iterations=(\d+)$"
    )
    result_pattern = re.compile(
        rf"^(axpy|copy|dot),(\d+),(\d+),({NUMBER}),({NUMBER}),"
    )
    power_pattern = re.compile(
        rf"^\[POWER\] mean=({NUMBER}) W std=({NUMBER}) W CV=({NUMBER})% "
        r"selected=(\d+)/(\d+) quality=(\S+)$"
    )
    rows = []
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        match = run_pattern.match(line)
        if match:
            if current is not None:
                raise ValueError(f"incomplete measurement before: {line}")
            current = {
                "kernel": match.group(1),
                "phase": match.group(2),
                "n": int(match.group(3)),
                "iterations": int(match.group(4)),
            }
            continue
        result = result_pattern.match(line)
        if result and current is not None:
            if (result.group(1) != current["kernel"] or
                    int(result.group(2)) != current["n"] or
                    int(result.group(3)) != current["iterations"]):
                raise ValueError(f"measurement header/result mismatch: {line}")
            current["total_kernel_time_s"] = float(result.group(4))
            current["actual_runtime_ms"] = float(result.group(5))
            continue
        power = power_pattern.match(line)
        if power and current is not None:
            if "actual_runtime_ms" not in current:
                raise ValueError(f"power precedes runtime: {current}")
            current.update({
                "actual_power_W": float(power.group(1)),
                "power_std_W": float(power.group(2)),
                "power_cv_percent": float(power.group(3)),
                "selected_power_samples": int(power.group(4)),
                "total_power_samples": int(power.group(5)),
                "power_quality": power.group(6),
            })
            current["actual_energy_J"] = (
                current["actual_runtime_ms"] / 1000.0
                * current["actual_power_W"]
            )
            rows.append(current)
            current = None
    if current is not None:
        raise ValueError(f"final incomplete measurement: {current}")
    expected = {
        (kernel, phase, n)
        for kernel in KERNELS
        for phase, sizes in (("train", TRAIN_SIZES), ("target", TARGET_SIZES))
        for n in sizes
    }
    actual = {(row["kernel"], row["phase"], row["n"]) for row in rows}
    if actual != expected:
        raise ValueError(
            f"measurement key mismatch; missing={sorted(expected-actual)}, "
            f"extra={sorted(actual-expected)}"
        )
    add_static_features(rows, wavefront_size)
    return rows


def read_predictions(path: Path) -> dict[tuple[str, int], dict]:
    rows = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for source in csv.DictReader(stream):
            row = {
                "kernel": source["kernel"],
                "n": int(source["n"]),
                "flops": float(source["flops"]),
                "loads": float(source["loads"]),
                "stores": float(source["stores"]),
                "predicted_runtime_ms": float(source["predicted_runtime_ms"]),
            }
            rows[(row["kernel"], row["n"])] = row
    expected = {(kernel, n) for kernel in KERNELS for n in TARGET_SIZES}
    if set(rows) != expected:
        raise ValueError("official prediction keys do not match the 21 target points")
    return rows


def mean(values) -> float:
    values = list(values)
    return float(np.mean(values))


def evaluate(measurements: list[dict], predictions: dict, power_model: dict,
             wavefront_size: int) -> tuple[list[dict], list[dict], list[dict]]:
    comparisons = []
    decomposition = []
    for actual in measurements:
        if actual["phase"] != "target":
            continue
        predicted = predictions[(actual["kernel"], actual["n"])]
        runtime_ms = predicted["predicted_runtime_ms"]
        predicted_power = power_from_features(
            power_model,
            actual["n"] / wavefront_size,
            predicted["flops"],
            predicted["loads"],
            predicted["stores"],
            runtime_ms,
        )
        predicted_energy = runtime_ms / 1000.0 * predicted_power
        if not all(math.isfinite(value) and value > 0 for value in (
                runtime_ms, predicted_power, predicted_energy)):
            raise RuntimeError(f"invalid prediction for {actual['kernel']} {actual['n']}")
        measured_runtime_power = power_from_features(
            power_model,
            actual["warps"],
            actual["flops"],
            actual["loads_bytes"],
            actual["stores_bytes"],
            actual["actual_runtime_ms"],
        )
        comparison = {
            "kernel": actual["kernel"],
            "n": actual["n"],
            "actual_runtime_ms": actual["actual_runtime_ms"],
            "predicted_runtime_ms": runtime_ms,
            "runtime_ape_percent": 100.0 * abs(
                runtime_ms / actual["actual_runtime_ms"] - 1.0
            ),
            "actual_power_W": actual["actual_power_W"],
            "predicted_power_W": predicted_power,
            "power_ape_percent": 100.0 * abs(
                predicted_power / actual["actual_power_W"] - 1.0
            ),
            "actual_energy_J": actual["actual_energy_J"],
            "predicted_energy_J": predicted_energy,
            "energy_ape_percent": 100.0 * abs(
                predicted_energy / actual["actual_energy_J"] - 1.0
            ),
            "power_cv_percent": actual["power_cv_percent"],
            "selected_power_samples": actual["selected_power_samples"],
            "power_quality": actual["power_quality"],
        }
        comparisons.append(comparison)
        decomposition.extend((
            {
                "kernel": actual["kernel"],
                "n": actual["n"],
                "scenario": "measured_runtime_exact_static_features",
                "actual_power_W": actual["actual_power_W"],
                "predicted_power_W": measured_runtime_power,
                "power_ape_percent": 100.0 * abs(
                    measured_runtime_power / actual["actual_power_W"] - 1.0
                ),
            },
            {
                "kernel": actual["kernel"],
                "n": actual["n"],
                "scenario": "predicted_runtime_official_static_features",
                "actual_power_W": actual["actual_power_W"],
                "predicted_power_W": predicted_power,
                "power_ape_percent": comparison["power_ape_percent"],
            },
        ))
    summary = []
    for group in ("all", *KERNELS):
        selected = comparisons if group == "all" else [
            row for row in comparisons if row["kernel"] == group
        ]
        summary.append({
            "group": group,
            "points": len(selected),
            "runtime_mape_percent": mean(
                row["runtime_ape_percent"] for row in selected
            ),
            "power_mape_percent": mean(
                row["power_ape_percent"] for row in selected
            ),
            "energy_mape_percent": mean(
                row["energy_ape_percent"] for row in selected
            ),
        })
    return comparisons, summary, decomposition


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment-root", required=True, type=Path)
    parser.add_argument("--base-machine", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--wavefront-size", type=int, default=64)
    args = parser.parse_args()
    started_at = utc_now()
    start = time.perf_counter()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    measurements = parse_measurements(
        args.experiment_root / "measurement/measurement.log",
        args.wavefront_size,
    )
    predictions = read_predictions(
        args.experiment_root / "predictions/predictions.csv"
    )
    train = [row for row in measurements if row["phase"] == "train"]
    power_model, fitted = fit_power(train)
    write_json(output / "training/power_model.json", power_model)
    fitted_rows = []
    for row, predicted_power in zip(train, fitted):
        fitted_rows.append({
            "kernel": row["kernel"],
            "n": row["n"],
            "actual_power_W": row["actual_power_W"],
            "fitted_power_W": float(predicted_power),
            "power_ape_percent": 100.0 * abs(
                predicted_power / row["actual_power_W"] - 1.0
            ),
        })
    write_csv(output / "training/power_training_fitted_values.csv", fitted_rows)
    comparisons, summary, decomposition = evaluate(
        measurements, predictions, power_model, args.wavefront_size
    )
    write_csv(output / "evaluation/power_energy_comparison.csv", comparisons)
    write_csv(output / "evaluation/mape_summary.csv", summary)
    write_csv(output / "evaluation/power_error_decomposition.csv", decomposition)
    runtime_model = json.loads(
        (args.experiment_root / "training/runtime_model.json").read_text(
            encoding="utf-8"
        )
    )
    updated, block = build_machine_model(
        args.base_machine.read_text(encoding="utf-8"),
        runtime_model,
        power_model,
        args.wavefront_size,
    )
    model_dir = output / "machine_model"
    model_dir.mkdir(parents=True, exist_ok=True)
    (model_dir / "amd_mi300a_sirius_type0_runtime_power.aspen").write_text(
        updated, encoding="utf-8"
    )
    (model_dir / "parameter_block.aspen").write_text(block, encoding="utf-8")
    elapsed = time.perf_counter() - start
    write_json(output / "analysis_metadata.json", {
        "status": "COMPLETE",
        "started_at_utc": started_at,
        "ended_at_utc": utc_now(),
        "elapsed_seconds": elapsed,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "wavefront_size": args.wavefront_size,
        "training_rows": len(train),
        "validation_rows": len(comparisons),
        "power_measurement_max_cv_percent": max(
            row["power_cv_percent"] for row in measurements
        ),
        "mape": summary,
    })
    overall = summary[0]
    log = f"""# Type0 power/energy post-analysis

- Status: COMPLETE
- Completed (UTC): {utc_now()}
- Source Sirius job: 51388.pbs
- Training rows: {len(train)}
- Validation rows: {len(comparisons)}
- Wavefront size: {args.wavefront_size}
- Ridge alpha: {power_model['alpha']:.9g}
- Power train MAPE: {power_model['train_mape_percent']:.6g}%
- Power leave-one-size-out MAPE: {power_model['leave_one_size_out_mape_percent']:.6g}%
- Target power MAPE: {overall['power_mape_percent']:.6g}%
- Target energy MAPE: {overall['energy_mape_percent']:.6g}%
- Analysis elapsed: {elapsed:.6f} s
- LLM prompt/completion tokens: 0 / 0

No Sirius job was submitted. The analysis used the 45 measurements and 21
official runtime/static-feature predictions already archived by 51388.pbs.
The machine model written here is a local provisional artifact; the canonical
GenASPEN MI300A model was not modified.
"""
    (output / "EXECUTION_LOG.md").write_text(log, encoding="utf-8")
    print(json.dumps({
        "status": "COMPLETE",
        "alpha": power_model["alpha"],
        "power_train_mape_percent": power_model["train_mape_percent"],
        "power_loso_mape_percent": power_model["leave_one_size_out_mape_percent"],
        "target_mape": summary,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
