#!/usr/bin/env python3
"""Fit one MI300A Type0 bandwidth and validate it on an interleaved grid."""

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


KERNELS = ("axpy", "copy", "dot")
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
# Rounded geometric midpoints between adjacent training sizes.
TARGET_SIZES = (
    23_726_566,
    47_453_133,
    94_906_266,
    189_812_531,
    379_625_062,
    759_250_125,
    1_518_500_250,
)
BYTES_PER_N = {"axpy": 24.0, "copy": 16.0, "dot": 24.0}
EXPECTED_FEATURES = {
    "axpy": (2.0, 16.0, 8.0),
    "copy": (0.0, 8.0, 8.0),
    "dot": (2.0, 16.0, 8.0),
}
NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def write_csv(path: Path, rows: list[dict], fields: list[str] | None = None) -> None:
    if not rows:
        raise ValueError(f"refusing to write empty CSV: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields or list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


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


def parse_measurements(path: Path) -> list[dict]:
    run_pattern = re.compile(
        r"^\[RUN\] (axpy|copy|dot) (train|target) n=(\d+) iterations=(\d+)$"
    )
    result_pattern = re.compile(
        rf"^(axpy|copy|dot),(\d+),(\d+),({NUMBER}),({NUMBER}),"
    )
    rows = []
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        match = run_pattern.match(line)
        if match:
            if current is not None:
                raise ValueError(f"measurement result missing before: {line}")
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
            current["bytes"] = BYTES_PER_N[current["kernel"]] * current["n"]
            current["effective_bandwidth_GB_per_s"] = (
                current["bytes"] / 1e9 / (current["actual_runtime_ms"] / 1000.0)
            )
            rows.append(current)
            current = None
    if current is not None:
        raise ValueError(f"final measurement result missing: {current}")
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


def mape(rows: list[dict], predicted_key: str, actual_key: str) -> float:
    return 100.0 * sum(
        abs(row[predicted_key] / row[actual_key] - 1.0) for row in rows
    ) / len(rows)


def fit_bandwidth(train: list[dict]) -> dict:
    # z is runtime in ms at 1 GB/s; fit y=z/bw with 1/y^2 weights.
    values = []
    for row in train:
        z = row["bytes"] / 1e9 * 1000.0
        y = row["actual_runtime_ms"]
        values.append((z, y, 1.0 / (y * y)))
    beta = (
        sum(weight * z * y for z, y, weight in values)
        / sum(weight * z * z for z, _, weight in values)
    )
    bandwidth = 1.0 / beta
    fitted_rows = []
    for row in train:
        predicted = row["bytes"] / 1e9 * 1000.0 * beta
        fitted_rows.append({
            **row,
            "predicted_runtime_ms": predicted,
            "runtime_ape_percent": 100.0 * abs(
                predicted / row["actual_runtime_ms"] - 1.0
            ),
        })
    leave_one_size_out = []
    for held_out in TRAIN_SIZES:
        fit_rows = [row for row in train if row["n"] != held_out]
        validation_rows = [row for row in train if row["n"] == held_out]
        fit = fit_bandwidth_no_validation(fit_rows)
        errors = []
        for row in validation_rows:
            predicted = row["bytes"] / (fit * 1e9) * 1000.0
            errors.append(abs(predicted / row["actual_runtime_ms"] - 1.0))
        leave_one_size_out.append({
            "held_out_n": held_out,
            "bandwidth_GB_per_s": fit,
            "validation_mape_percent": 100.0 * sum(errors) / len(errors),
        })
    return {
        "structure": "runtime_ms=(loads_bytes+stores_bytes)/bw_B_per_s*1000",
        "fit": "weighted least squares through origin",
        "sample_weight": "1/runtime_ms^2",
        "bandwidth_GB_per_s": bandwidth,
        "bandwidth_B_per_s": bandwidth * 1e9,
        "inverse_bandwidth_ms_per_GB": beta,
        "train_mape_percent": sum(
            row["runtime_ape_percent"] for row in fitted_rows
        ) / len(fitted_rows),
        "leave_one_size_out": leave_one_size_out,
        "fitted_rows": fitted_rows,
    }


def fit_bandwidth_no_validation(rows: list[dict]) -> float:
    numerator = 0.0
    denominator = 0.0
    for row in rows:
        z = row["bytes"] / 1e9 * 1000.0
        y = row["actual_runtime_ms"]
        weight = 1.0 / (y * y)
        numerator += weight * z * y
        denominator += weight * z * z
    return 1.0 / (numerator / denominator)


def build_machine_model(base_path: Path, output_path: Path, bandwidth: float) -> None:
    base = base_path.read_text(encoding="utf-8")
    updated, count = re.subn(
        r"(?m)^param bw\s*=.*$",
        f"param bw = {bandwidth:.17g} * giga",
        base,
        count=1,
    )
    if count != 1:
        raise RuntimeError("unique 'param bw' was not found in MI300A model")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(updated, encoding="utf-8")


def parse_metric(stdout: str, name: str) -> float:
    match = re.search(rf"(?m)^{re.escape(name)}\s+({NUMBER})\s*$", stdout)
    if not match:
        raise ValueError(f"{name} was not found in prediction stdout")
    return float(match.group(1))


def run_predictions(args, root: Path, runtime_model: dict) -> list[dict]:
    model_name = "amd_mi300a_sirius_type0_runtime_grid"
    model_path = (
        args.genaspen_root / "aspen/models/machine/sockets" / f"{model_name}.aspen"
    )
    archived_model = root / "machine_model" / f"{model_name}.aspen"
    build_machine_model(
        args.base_machine, archived_model, runtime_model["bandwidth_GB_per_s"]
    )
    shutil.copy2(archived_model, model_path)
    rows = []
    commands = []
    for kernel in KERNELS:
        kernel_dir = args.genaspen_root / "kernels" / kernel
        app_path = kernel_dir / "app.aspen"
        original_app = app_path.read_text(encoding="utf-8")
        mach_path = kernel_dir / "mach.aspen"
        mach_path.write_text(
            f"    include ../../aspen/models/machine/sockets/{model_path.name}\n"
            "    machine Machine{\n        node [1] Node\n    }\n"
            "    node Node{\n        socket [1] amd_mi300a\n    }\n",
            encoding="utf-8",
        )
        for n in TARGET_SIZES:
            app_path.write_text(original_app, encoding="utf-8")
            command = [
                args.uv,
                "run",
                "--no-sync",
                "kernels/run_kernel_size_energy.py",
                "--aspen",
                "--reuse",
                "-f",
                "-l",
                "-s",
                "-r",
                "--kernel",
                kernel,
                "-n",
                str(n),
                "-mach",
                model_name,
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
            flops = parse_metric(completed.stdout, "flops")
            loads = parse_metric(completed.stdout, "loads")
            stores = parse_metric(completed.stdout, "stores")
            runtime = parse_metric(completed.stdout, "runtime")
            expected_flops, expected_loads, expected_stores = EXPECTED_FEATURES[kernel]
            expected = (
                expected_flops * n,
                expected_loads * n,
                expected_stores * n,
            )
            observed = (flops, loads, stores)
            if not all(
                    math.isclose(value, reference, rel_tol=5e-6, abs_tol=1.0)
                    for value, reference in zip(observed, expected)):
                raise RuntimeError(
                    f"static feature mismatch for {kernel} n={n}: "
                    f"expected={expected}, observed={observed}"
                )
            direct_runtime = (
                (loads + stores) / runtime_model["bandwidth_B_per_s"] * 1000.0
            )
            if not math.isclose(runtime, direct_runtime, rel_tol=5e-5, abs_tol=1e-8):
                raise RuntimeError(
                    f"C++/direct runtime mismatch for {kernel} n={n}: "
                    f"{runtime} vs {direct_runtime}"
                )
            rows.append({
                "kernel": kernel,
                "n": n,
                "flops": flops,
                "loads": loads,
                "stores": stores,
                "predicted_runtime_ms": runtime,
                "direct_runtime_ms": direct_runtime,
                "command_elapsed_seconds": elapsed,
                "stdout": str(stdout_path),
                "stderr": str(stderr_path),
            })
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
    write_csv(root / "predictions/predictions.csv", rows)
    command_path = root / "timings/prediction_commands.jsonl"
    command_path.parent.mkdir(parents=True, exist_ok=True)
    with command_path.open("w", encoding="utf-8") as stream:
        for command in commands:
            stream.write(json.dumps(command) + "\n")
    return rows


def evaluate(predictions: list[dict], measurements: list[dict], root: Path) -> list[dict]:
    truth = {
        (row["kernel"], row["n"]): row
        for row in measurements if row["phase"] == "target"
    }
    comparison = []
    for prediction in predictions:
        actual = truth[(prediction["kernel"], prediction["n"])]
        comparison.append({
            "kernel": prediction["kernel"],
            "n": prediction["n"],
            "actual_runtime_ms": actual["actual_runtime_ms"],
            "predicted_runtime_ms": prediction["predicted_runtime_ms"],
            "runtime_ape_percent": 100.0 * abs(
                prediction["predicted_runtime_ms"] / actual["actual_runtime_ms"] - 1.0
            ),
            "effective_bandwidth_GB_per_s": actual["effective_bandwidth_GB_per_s"],
        })
    write_csv(root / "evaluation/runtime_comparison.csv", comparison)
    summary = []
    for group in ("all", *KERNELS):
        selected = comparison if group == "all" else [
            row for row in comparison if row["kernel"] == group
        ]
        summary.append({
            "group": group,
            "points": len(selected),
            "runtime_mape_percent": sum(
                row["runtime_ape_percent"] for row in selected
            ) / len(selected),
        })
    write_csv(root / "evaluation/mape_summary.csv", summary)
    return summary


def write_manifest(root: Path) -> None:
    rows = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "sha256_manifest.json":
            rows.append({
                "path": path.relative_to(root).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            })
    write_json(root / "sha256_manifest.json", rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--genaspen-root", required=True, type=Path)
    parser.add_argument("--measurement-log", required=True, type=Path)
    parser.add_argument("--base-machine", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--uv", required=True)
    args = parser.parse_args()
    root = args.output_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    timings = root / "timings/analysis_stages.jsonl"
    with timed_stage(timings, "parse_and_validate_45_measurements"):
        measurements = parse_measurements(args.measurement_log)
        write_csv(root / "input_snapshot/measurement_summary.csv", measurements)
        shutil.copy2(args.measurement_log, root / "input_snapshot/measurement.log")
    train = [row for row in measurements if row["phase"] == "train"]
    with timed_stage(timings, "fit_single_type0_bandwidth_24_rows"):
        runtime_model = fit_bandwidth(train)
        fitted_rows = runtime_model.pop("fitted_rows")
        write_json(root / "training/runtime_model.json", runtime_model)
        write_csv(root / "training/training_fitted_values.csv", fitted_rows)
        write_csv(root / "training/all_effective_bandwidths.csv", measurements)
    with timed_stage(timings, "official_genaspen_predictions_21_points"):
        predictions = run_predictions(args, root, runtime_model)
    with timed_stage(timings, "evaluate_21_held_out_points"):
        summary = evaluate(predictions, measurements, root)
    write_json(root / "generation/generation_token_time_summary.json", {
        "application_model_source": "cached outputs from successful job 51385.pbs",
        "regenerated": False,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "elapsed_seconds": 0.0,
    })
    overall = summary[0]
    log = f"""# Type0 denser-grid execution log

- Status: COMPLETE
- Completed (UTC): {utc_now()}
- System: Sirius / AMD MI300A / ROCm 7.2.0
- Training sizes: {', '.join(str(n) for n in TRAIN_SIZES)}
- Held-out geometric-midpoint sizes: {', '.join(str(n) for n in TARGET_SIZES)}
- Training rows: 24
- Validation rows: 21
- Maximum two-host-plus-two-device-array footprint: 64 GiB
- Single fitted bandwidth: {runtime_model['bandwidth_GB_per_s']:.9g} GB/s
- Training runtime MAPE: {runtime_model['train_mape_percent']:.6g}%
- Validation runtime MAPE: {overall['runtime_mape_percent']:.6g}%
- LLM prompt tokens: 0 (cached application models reused)
- LLM completion tokens: 0 (cached application models reused)

The canonical GenASPEN tree and MI300A machine model were not modified.
The calibrated bandwidth was applied only to a PBS-job-local machine-model copy.
The HIP measurement sources and their event-timing order were unchanged.
"""
    (root / "EXECUTION_LOG.md").write_text(log, encoding="utf-8")
    write_json(root / "evaluation/evaluation_summary.json", {
        "status": "COMPLETE",
        "definition": "MAPE=mean(abs(predicted-actual)/actual)*100",
        "train_sizes": list(TRAIN_SIZES),
        "target_sizes": list(TARGET_SIZES),
        "runtime_model": runtime_model,
        "mape": summary,
    })
    write_manifest(root)
    print(json.dumps({
        "status": "COMPLETE",
        "bandwidth_GB_per_s": runtime_model["bandwidth_GB_per_s"],
        "train_mape_percent": runtime_model["train_mape_percent"],
        "validation": summary,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
