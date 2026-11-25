#!/usr/bin/env python3
"""Calibrate and validate Type0 runtime, power, and energy for six kernels."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import shutil
import subprocess
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from run_type0_analysis import (
    build_machine_model,
    fit_power,
    parse_metric,
    power_from_features,
    write_csv,
    write_json,
)
from run_type0_runtime_grid import fit_bandwidth


KERNELS = ("axpy", "copy", "dot", "softmax", "gelu", "relu")
TRAIN_SIZES = (
    16_777_216,
    33_554_432,
    67_108_864,
    134_217_728,
    268_435_456,
    536_870_912,
    1_073_741_824,
    2_147_483_648,
)
TARGET_SIZES = (
    23_726_566,
    47_453_133,
    94_906_266,
    189_812_531,
    379_625_062,
    759_250_125,
    1_518_500_250,
)
# Static features must use the same convention as each cached ASPEN model.
PROFILES = {
    "axpy": (2.0, 16.0, 8.0),
    "copy": (0.0, 8.0, 8.0),
    "dot": (2.0, 16.0, 8.0),
    "softmax": (3.0, 16.0, 8.0),
    "gelu": (9.0, 8.0, 8.0),
    "relu": (0.0, 8.0, 8.0),
}
NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@contextmanager
def timed_stage(path: Path, stage: str):
    started_at = utc_now()
    start = time.perf_counter()
    status = "complete"
    try:
        yield
    except Exception:
        status = "failed"
        raise
    finally:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({
                "stage": stage,
                "started_at_utc": started_at,
                "ended_at_utc": utc_now(),
                "elapsed_seconds": time.perf_counter() - start,
                "status": status,
                "prompt_tokens": 0,
                "completion_tokens": 0,
            }) + "\n")


def parse_measurements(path: Path, wavefront_size: int) -> list[dict]:
    names = "|".join(KERNELS)
    run_pattern = re.compile(
        rf"^\[RUN\] ({names}) (train|target) n=(\d+) iterations=(\d+)$"
    )
    result_pattern = re.compile(
        rf"^({names}),(\d+),(\d+),({NUMBER}),({NUMBER}),"
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
            flops, loads, stores = PROFILES[current["kernel"]]
            n = float(current["n"])
            current.update({
                "execution_group": "wavefront",
                "wavefront_size": wavefront_size,
                "warps": n / wavefront_size,
                "flops": flops * n,
                "loads_bytes": loads * n,
                "stores_bytes": stores * n,
                "bytes": (loads + stores) * n,
            })
            current["effective_bandwidth_GB_per_s"] = (
                current["bytes"] / 1e9
                / (current["actual_runtime_ms"] / 1000.0)
            )
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
    return rows


def run_predictions(args, root: Path, runtime_model: dict,
                    power_model: dict) -> list[dict]:
    model_name = "amd_mi300a_sirius_type0_six_kernel"
    live_model = (
        args.genaspen_root / "aspen/models/machine/sockets" / f"{model_name}.aspen"
    )
    archived_model = root / "machine_model" / live_model.name
    updated, block = build_machine_model(
        args.base_machine.read_text(encoding="utf-8"),
        runtime_model,
        power_model,
        args.wavefront_size,
    )
    old_comment = "// Sirius MI300A Type0 calibration: axpy/copy/dot train rows only"
    new_comment = "// Sirius MI300A Type0 calibration: six-kernel train rows only"
    updated = updated.replace(old_comment, new_comment, 1)
    block = block.replace(old_comment, new_comment, 1)
    archived_model.parent.mkdir(parents=True, exist_ok=True)
    archived_model.write_text(updated, encoding="utf-8")
    shutil.copy2(archived_model, live_model)
    (archived_model.parent / "parameter_block.aspen").write_text(
        block, encoding="utf-8"
    )
    rows = []
    commands = []
    for kernel in KERNELS:
        kernel_dir = args.genaspen_root / "kernels" / kernel
        app_path = kernel_dir / "app.aspen"
        original_app = app_path.read_text(encoding="utf-8")
        original_hash = sha256(app_path)
        (kernel_dir / "mach.aspen").write_text(
            f"    include ../../aspen/models/machine/sockets/{live_model.name}\n"
            "    machine Machine{\n        node [1] Node\n    }\n"
            "    node Node{\n        socket [1] amd_mi300a\n    }\n",
            encoding="utf-8",
        )
        for n in TARGET_SIZES:
            app_path.write_text(original_app, encoding="utf-8")
            command = [
                args.uv, "run", "--no-sync",
                "kernels/run_kernel_size_energy.py",
                "--aspen", "--reuse", "-f", "-l", "-s", "-r", "-p",
                "--kernel", kernel, "-n", str(n), "-mach", model_name,
            ]
            started_at = utc_now()
            start = time.perf_counter()
            try:
                completed = subprocess.run(
                    command,
                    cwd=args.genaspen_root,
                    capture_output=True,
                    text=True,
                    timeout=120,
                    check=False,
                )
            finally:
                app_path.write_text(original_app, encoding="utf-8")
            elapsed = time.perf_counter() - start
            stdout_path = root / "predictions/raw_stdout" / f"{kernel}_n_{n}.txt"
            stderr_path = root / "predictions/raw_stderr" / f"{kernel}_n_{n}.txt"
            stdout_path.parent.mkdir(parents=True, exist_ok=True)
            stderr_path.parent.mkdir(parents=True, exist_ok=True)
            stdout_path.write_text(completed.stdout, encoding="utf-8")
            stderr_path.write_text(completed.stderr, encoding="utf-8")
            if completed.returncode != 0:
                raise RuntimeError(
                    f"prediction failed for {kernel} n={n}: {completed.stderr}"
                )
            row = {
                "kernel": kernel,
                "n": n,
                "flops": parse_metric(completed.stdout, "flops"),
                "loads": parse_metric(completed.stdout, "loads"),
                "stores": parse_metric(completed.stdout, "stores"),
                "runtime": parse_metric(completed.stdout, "runtime"),
                "power_W": parse_metric(completed.stdout, "power_W"),
                "energy_J": parse_metric(completed.stdout, "energy_J"),
                "command_elapsed_seconds": elapsed,
                "stdout": str(stdout_path),
                "stderr": str(stderr_path),
            }
            for metric in ("flops", "loads", "stores", "runtime", "power_W", "energy_J"):
                value = row[metric]
                if value is None or not math.isfinite(value):
                    raise RuntimeError(f"invalid {metric} for {kernel} n={n}: {value}")
            if any(row[metric] <= 0 for metric in ("runtime", "power_W", "energy_J")):
                raise RuntimeError(f"non-positive runtime/power/energy for {kernel} n={n}")
            expected = tuple(value * n for value in PROFILES[kernel])
            observed = (row["flops"], row["loads"], row["stores"])
            if not all(
                    math.isclose(value, reference, rel_tol=5e-6, abs_tol=1.0)
                    for value, reference in zip(observed, expected)):
                raise RuntimeError(
                    f"static feature mismatch for {kernel} n={n}: "
                    f"expected={expected}, observed={observed}"
                )
            direct_runtime = (
                (row["loads"] + row["stores"])
                / runtime_model["bandwidth_B_per_s"] * 1000.0
            )
            direct_power = power_from_features(
                power_model, n / args.wavefront_size,
                row["flops"], row["loads"], row["stores"], row["runtime"],
            )
            direct_energy = row["runtime"] / 1000.0 * row["power_W"]
            if not (
                math.isclose(row["runtime"], direct_runtime, rel_tol=5e-5, abs_tol=1e-8)
                and math.isclose(row["power_W"], direct_power, rel_tol=5e-5, abs_tol=1e-6)
                and math.isclose(row["energy_J"], direct_energy, rel_tol=1e-4, abs_tol=1e-8)
            ):
                raise RuntimeError(f"native/direct predictor mismatch: {kernel} n={n}")
            rows.append(row)
            commands.append({
                "kernel": kernel,
                "n": n,
                "started_at_utc": started_at,
                "ended_at_utc": utc_now(),
                "elapsed_seconds": elapsed,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "command": command,
                "returncode": completed.returncode,
            })
        if sha256(app_path) != original_hash:
            raise RuntimeError(f"cached application model was not restored: {kernel}")
    write_csv(root / "predictions/predictions.csv", rows)
    command_path = root / "timings/prediction_commands.jsonl"
    command_path.parent.mkdir(parents=True, exist_ok=True)
    with command_path.open("w", encoding="utf-8") as stream:
        for command in commands:
            stream.write(json.dumps(command) + "\n")
    return rows


def mean(values) -> float:
    return float(np.mean(list(values)))


def evaluate(predictions: list[dict], measurements: list[dict],
             root: Path) -> list[dict]:
    truth = {
        (row["kernel"], row["n"]): row
        for row in measurements if row["phase"] == "target"
    }
    comparisons = []
    for predicted in predictions:
        actual = truth[(predicted["kernel"], predicted["n"])]
        comparisons.append({
            "kernel": predicted["kernel"],
            "n": predicted["n"],
            "actual_runtime_ms": actual["actual_runtime_ms"],
            "predicted_runtime_ms": predicted["runtime"],
            "runtime_ape_percent": 100.0 * abs(
                predicted["runtime"] / actual["actual_runtime_ms"] - 1.0
            ),
            "actual_power_W": actual["actual_power_W"],
            "predicted_power_W": predicted["power_W"],
            "power_ape_percent": 100.0 * abs(
                predicted["power_W"] / actual["actual_power_W"] - 1.0
            ),
            "actual_energy_J": actual["actual_energy_J"],
            "predicted_energy_J": predicted["energy_J"],
            "energy_ape_percent": 100.0 * abs(
                predicted["energy_J"] / actual["actual_energy_J"] - 1.0
            ),
            "power_cv_percent": actual["power_cv_percent"],
            "power_quality": actual["power_quality"],
        })
    write_csv(root / "evaluation/end_to_end_comparison.csv", comparisons)
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
    write_csv(root / "evaluation/mape_summary.csv", summary)
    return summary


def write_manifest(root: Path) -> None:
    entries = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "sha256_manifest.json":
            entries.append({
                "path": path.relative_to(root).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            })
    write_json(root / "sha256_manifest.json", entries)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--genaspen-root", required=True, type=Path)
    parser.add_argument("--measurement-log", required=True, type=Path)
    parser.add_argument("--base-machine", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--wavefront-size", type=int, default=64)
    parser.add_argument("--uv", required=True)
    parser.add_argument(
        "--measurement-note",
        default=(
            "The axpy/copy/dot measurements came from successful job 51388.pbs. "
            "This job newly measured softmax/gelu/relu on the same grid."
        ),
    )
    args = parser.parse_args()
    root = args.output_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    timings = root / "timings/analysis_stages.jsonl"
    with timed_stage(timings, "parse_and_validate_90_measurements"):
        measurements = parse_measurements(
            args.measurement_log, args.wavefront_size
        )
        write_csv(root / "input_snapshot/measurement_summary.csv", measurements)
        shutil.copy2(args.measurement_log, root / "input_snapshot/measurement.log")
    train = [row for row in measurements if row["phase"] == "train"]
    with timed_stage(timings, "fit_runtime_bandwidth_48_rows"):
        runtime_model = fit_bandwidth(train)
        runtime_fitted = runtime_model.pop("fitted_rows")
        write_json(root / "training/runtime_model.json", runtime_model)
        write_csv(root / "training/runtime_training_fitted_values.csv", runtime_fitted)
    with timed_stage(timings, "fit_power_ridge_48_rows"):
        power_model, power_fitted = fit_power(train)
        power_model["training_kernels"] = list(KERNELS)
        if power_model["design_matrix_rank"] < power_model["design_matrix_columns"]:
            power_model["collinearity_note"] = (
                "The six-kernel rate-feature matrix is rank deficient; interpret "
                "the combined predictor rather than individual coefficients."
            )
        else:
            power_model["collinearity_note"] = (
                "The six-kernel standardized rate-feature matrix has full column rank."
            )
        write_json(root / "training/power_model.json", power_model)
        power_rows = []
        for row, value in zip(train, power_fitted):
            power_rows.append({
                "kernel": row["kernel"],
                "n": row["n"],
                "actual_power_W": row["actual_power_W"],
                "fitted_power_W": float(value),
                "power_ape_percent": 100.0 * abs(
                    value / row["actual_power_W"] - 1.0
                ),
            })
        write_csv(root / "training/power_training_fitted_values.csv", power_rows)
    with timed_stage(timings, "official_predictions_42_points"):
        predictions = run_predictions(args, root, runtime_model, power_model)
    with timed_stage(timings, "evaluate_42_held_out_points"):
        summary = evaluate(predictions, measurements, root)
    overall = summary[0]
    write_json(root / "generation/generation_token_time_summary.json", {
        "application_model_source": "cached application models",
        "regenerated": False,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "elapsed_seconds": 0.0,
    })
    execution_log = f"""# Type0 six-kernel grid execution log

- Status: COMPLETE
- Completed (UTC): {utc_now()}
- Source kernels: {', '.join(KERNELS)}
- Training rows: 48
- Validation rows: 42
- Runtime bandwidth: {runtime_model['bandwidth_GB_per_s']:.9g} GB/s
- Runtime train MAPE: {runtime_model['train_mape_percent']:.6g}%
- Power Ridge alpha: {power_model['alpha']:.9g}
- Power train MAPE: {power_model['train_mape_percent']:.6g}%
- Target runtime MAPE: {overall['runtime_mape_percent']:.6g}%
- Target power MAPE: {overall['power_mape_percent']:.6g}%
- Target energy MAPE: {overall['energy_mape_percent']:.6g}%
- LLM prompt/completion tokens: 0 / 0

{args.measurement_note}

The canonical GenASPEN tree and MI300A machine model were not modified; all
predictions used a job-local machine model and cached application models.
"""
    (root / "EXECUTION_LOG.md").write_text(execution_log, encoding="utf-8")
    write_json(root / "evaluation/evaluation_summary.json", {
        "status": "COMPLETE",
        "definition": "MAPE=mean(abs(predicted-actual)/actual)*100",
        "train_sizes": list(TRAIN_SIZES),
        "target_sizes": list(TARGET_SIZES),
        "runtime_model": runtime_model,
        "power_model": {
            key: power_model[key]
            for key in (
                "alpha", "intercept", "coefficients", "train_mape_percent",
                "leave_one_size_out_mape_percent", "design_matrix_rank",
                "design_matrix_condition_number",
            )
        },
        "mape": summary,
        "measurement_note": args.measurement_note,
    })
    write_manifest(root)
    print(json.dumps({
        "status": "COMPLETE",
        "bandwidth_GB_per_s": runtime_model["bandwidth_GB_per_s"],
        "runtime_train_mape_percent": runtime_model["train_mape_percent"],
        "power_train_mape_percent": power_model["train_mape_percent"],
        "validation": summary,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
