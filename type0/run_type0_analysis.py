#!/usr/bin/env python3
"""Calibrate MI300A Type0 and evaluate axpy/copy/dot target predictions."""

from __future__ import annotations

import argparse
import csv
import difflib
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
from sklearn.linear_model import Ridge
from sklearn.model_selection import LeaveOneGroupOut
from sklearn.preprocessing import StandardScaler


KERNELS = ("axpy", "copy", "dot")
TRAIN_SIZES = (4_194_304, 8_388_608, 16_777_216, 67_108_864,
               268_435_456, 1_073_741_824, 4_100_000_000)
TARGET_SIZES = (270_000_000, 1_000_000_000, 4_000_000_000)
PROFILES = {
    "axpy": (2.0, 16.0, 8.0),
    "copy": (0.0, 8.0, 8.0),
    "dot": (2.0, 16.0, 8.0),
}
POWER_FEATURES = ("warp_per_s", "flop_per_s", "load_per_s", "store_per_s")
POWER_COEFFICIENTS = ("warp", "flop", "load", "store")
ALPHAS = np.logspace(-12, 4, 33)
NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")


def write_csv(path: Path, rows: list[dict], fieldnames=None) -> None:
    if not rows:
        raise ValueError(f"refusing to write empty CSV: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    names = list(fieldnames or rows[0].keys())
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=names)
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
        record = {
            "stage": stage,
            "started_at_utc": started_at,
            "ended_at_utc": utc_now(),
            "elapsed_seconds": time.perf_counter() - start,
            "status": status,
            "prompt_tokens": None,
            "completion_tokens": None,
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record) + "\n")


def parse_measurements(path: Path) -> list[dict]:
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
    rows: list[dict] = []
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        run = run_pattern.match(line)
        if run:
            if current is not None:
                raise ValueError(f"incomplete measurement before: {line}")
            current = {
                "kernel": run.group(1),
                "phase": run.group(2),
                "n": int(run.group(3)),
                "iterations": int(run.group(4)),
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
                raise ValueError(f"power precedes runtime for {current}")
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
    if len(rows) != 30:
        raise ValueError(f"expected 30 axpy/copy/dot rows, found {len(rows)}")
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


def add_static_features(rows: list[dict], wavefront_size: int) -> None:
    for row in rows:
        flops_per_n, loads_per_n, stores_per_n = PROFILES[row["kernel"]]
        n = float(row["n"])
        row["execution_group"] = "wavefront"
        row["wavefront_size"] = wavefront_size
        row["warps"] = n / wavefront_size
        row["flops"] = flops_per_n * n
        row["loads_bytes"] = loads_per_n * n
        row["stores_bytes"] = stores_per_n * n


def mape(predicted: np.ndarray, actual: np.ndarray) -> float:
    return 100.0 * float(np.mean(np.abs(predicted / actual - 1.0)))


def fit_bandwidth(train: list[dict]) -> tuple[dict, np.ndarray]:
    # z has units ms at 1 GB/s, so y = z * (1 / bandwidth_GB_per_s).
    z = np.asarray([
        (row["loads_bytes"] + row["stores_bytes"]) / 1e9 * 1000.0
        for row in train
    ])
    y = np.asarray([row["actual_runtime_ms"] for row in train])
    weights = 1.0 / np.square(y)
    inverse_bw = float(np.sum(weights * z * y) / np.sum(weights * z * z))
    bandwidth_gbps = 1.0 / inverse_bw
    fitted = z * inverse_bw

    groups = sorted({row["n"] for row in train})
    validation = []
    for group in groups:
        fit_idx = np.asarray([row["n"] != group for row in train])
        val_idx = ~fit_idx
        beta = float(
            np.sum(weights[fit_idx] * z[fit_idx] * y[fit_idx])
            / np.sum(weights[fit_idx] * z[fit_idx] * z[fit_idx])
        )
        validation.append({
            "held_out_n": group,
            "bandwidth_GB_per_s": 1.0 / beta,
            "validation_mape_percent": mape(z[val_idx] * beta, y[val_idx]),
        })
    model = {
        "structure": "runtime_ms=(loads_bytes+stores_bytes)/bw_B_per_s*1000",
        "fit": "weighted least squares through origin",
        "sample_weight": "1/runtime_ms^2",
        "bandwidth_GB_per_s": bandwidth_gbps,
        "bandwidth_B_per_s": bandwidth_gbps * 1e9,
        "inverse_bandwidth_ms_per_GB": inverse_bw,
        "train_mape_percent": mape(fitted, y),
        "train_rmse_ms": float(np.sqrt(np.mean(np.square(fitted - y)))),
        "leave_one_size_out": validation,
        "leave_one_size_out_mape_percent": float(np.mean([
            item["validation_mape_percent"] for item in validation
        ])),
    }
    return model, fitted


def power_features(rows: list[dict], runtime_key: str) -> np.ndarray:
    values = []
    for row in rows:
        runtime_s = float(row[runtime_key]) / 1000.0
        values.append([
            row["warps"] / runtime_s,
            row["flops"] / runtime_s,
            row["loads_bytes"] / runtime_s,
            row["stores_bytes"] / runtime_s,
        ])
    return np.asarray(values, dtype=float)


def fit_power(train: list[dict]) -> tuple[dict, np.ndarray]:
    x = power_features(train, "actual_runtime_ms")
    y = np.asarray([row["actual_power_W"] for row in train])
    groups = np.asarray([row["n"] for row in train])
    logo = LeaveOneGroupOut()
    alpha_scores = []
    for alpha in ALPHAS:
        errors = []
        for fit_idx, validation_idx in logo.split(x, y, groups):
            scaler = StandardScaler().fit(x[fit_idx])
            model = Ridge(alpha=float(alpha))
            model.fit(
                scaler.transform(x[fit_idx]),
                y[fit_idx],
                sample_weight=1.0 / np.square(y[fit_idx]),
            )
            predicted = model.predict(scaler.transform(x[validation_idx]))
            errors.extend(np.abs(predicted / y[validation_idx] - 1.0))
        alpha_scores.append({
            "alpha": float(alpha),
            "leave_one_size_out_mape_percent": 100.0 * float(np.mean(errors)),
        })
    best = min(alpha_scores, key=lambda item: item["leave_one_size_out_mape_percent"])
    scaler = StandardScaler().fit(x)
    model = Ridge(alpha=best["alpha"])
    model.fit(
        scaler.transform(x),
        y,
        sample_weight=1.0 / np.square(y),
    )
    coefficients = model.coef_.astype(float) / scaler.scale_
    intercept = float(model.intercept_ - np.dot(coefficients, scaler.mean_))
    fitted = intercept + x @ coefficients
    library_fitted = model.predict(scaler.transform(x))
    if not np.allclose(fitted, library_fitted, rtol=1e-12, atol=1e-9):
        raise RuntimeError("raw power coefficient inverse transform failed")
    standardized = scaler.transform(x)
    result = {
        "structure": "intercept + warp/s + FLOP/s + load_byte/s + store_byte/s",
        "method": "StandardScaler -> Ridge",
        "sample_weight": "1/power_W^2",
        "alpha_selection": "train-only leave-one-size-out MAPE",
        "alpha": best["alpha"],
        "leave_one_size_out_mape_percent": best["leave_one_size_out_mape_percent"],
        "alpha_scores": alpha_scores,
        "features": list(POWER_FEATURES),
        "scaler_mean": scaler.mean_.tolist(),
        "scaler_scale": scaler.scale_.tolist(),
        "intercept": intercept,
        "coefficients": coefficients.tolist(),
        "coefficient_names": list(POWER_COEFFICIENTS),
        "train_mape_percent": mape(fitted, y),
        "train_rmse_W": float(np.sqrt(np.mean(np.square(fitted - y)))),
        "design_matrix_rank": int(np.linalg.matrix_rank(standardized)),
        "design_matrix_columns": int(standardized.shape[1]),
        "design_matrix_condition_number": float(np.linalg.cond(standardized)),
        "collinearity_note": (
            "axpy and dot have identical static operation ratios; Ridge is "
            "required because the four rate coefficients are not independently "
            "identifiable from these three kernels"
        ),
    }
    return result, fitted


def build_machine_model(base: str, runtime: dict, power: dict,
                        wavefront_size: int) -> tuple[str, str]:
    updated, count = re.subn(
        r"(?m)^param bw\s*=.*$",
        f"param bw = {runtime['bandwidth_GB_per_s']:.17g} * giga",
        base,
        count=1,
    )
    if count != 1:
        raise RuntimeError("unique 'param bw' was not found")
    if "power_intercept_0" in updated or "power_warp_size" in updated:
        raise RuntimeError("base MI300A model already contains Type0 power coefficients")
    values = dict(zip(POWER_COEFFICIENTS, power["coefficients"]))
    block = "\n".join([
        "// Sirius MI300A Type0 calibration: axpy/copy/dot train rows only",
        f"param power_warp_size = {wavefront_size}",
        f"param power_intercept_0 = {power['intercept']:.17g}",
        f"param power_warp_0 = {values['warp']:.17g}",
        f"param power_flop_0 = {values['flop']:.17g}",
        f"param power_load_0 = {values['load']:.17g}",
        f"param power_store_0 = {values['store']:.17g}",
    ])
    anchor = "socket amd_mi300a {"
    if updated.count(anchor) != 1:
        raise RuntimeError("unique MI300A socket anchor was not found")
    updated = updated.replace(anchor, block + "\n\n" + anchor, 1)
    return updated, block + "\n"


def collect_generation_metrics(debug_root: Path, output_dir: Path) -> dict:
    rows = []
    pattern = re.compile(r"(.+)_attempt(\d+)_metadata\.json$")
    for kernel in KERNELS:
        for path in sorted((debug_root / kernel).glob("*/*_metadata.json")):
            match = pattern.match(path.name)
            if not match:
                continue
            metadata = json.loads(path.read_text(encoding="utf-8"))
            if metadata.get("elapsed_seconds") is None:
                raise RuntimeError(f"instrumented elapsed time missing: {path}")
            rows.append({
                "kernel": kernel,
                "run_id": path.parent.name,
                "stage": match.group(1),
                "attempt": int(match.group(2)),
                "prompt_tokens": metadata.get("prompt_eval_count"),
                "completion_tokens": metadata.get("eval_count"),
                "elapsed_seconds": metadata["elapsed_seconds"],
                "done": metadata.get("done"),
                "done_reason": metadata.get("done_reason"),
                "metadata_path": str(path),
            })
    if not rows:
        raise RuntimeError(f"no generation metadata found under {debug_root}")
    for kernel in KERNELS:
        stages = {(row["stage"], row["attempt"]) for row in rows
                  if row["kernel"] == kernel}
        if ("json_ir", 1) not in stages or ("aspen", 1) not in stages:
            raise RuntimeError(f"required generation stages missing for {kernel}: {stages}")
    write_csv(output_dir / "generation_stage_metrics.csv", rows)
    summary = {
        "records": len(rows),
        "prompt_tokens": sum(int(row["prompt_tokens"] or 0) for row in rows),
        "completion_tokens": sum(int(row["completion_tokens"] or 0) for row in rows),
        "elapsed_seconds": sum(float(row["elapsed_seconds"]) for row in rows),
        "by_kernel": {},
    }
    for kernel in KERNELS:
        selected = [row for row in rows if row["kernel"] == kernel]
        summary["by_kernel"][kernel] = {
            "attempt_records": len(selected),
            "prompt_tokens": sum(int(row["prompt_tokens"] or 0) for row in selected),
            "completion_tokens": sum(int(row["completion_tokens"] or 0) for row in selected),
            "elapsed_seconds": sum(float(row["elapsed_seconds"]) for row in selected),
        }
    write_json(output_dir / "generation_token_time_summary.json", summary)
    return summary


def parse_metric(stdout: str, name: str):
    match = re.search(rf"(?m)^{re.escape(name)}\s+({NUMBER})\s*$", stdout)
    return float(match.group(1)) if match else None


def power_from_features(power: dict, warps: float, flops: float,
                        loads: float, stores: float, runtime_ms: float) -> float:
    runtime_s = runtime_ms / 1000.0
    features = np.asarray([
        warps / runtime_s,
        flops / runtime_s,
        loads / runtime_s,
        stores / runtime_s,
    ])
    return float(power["intercept"] + features @ np.asarray(power["coefficients"]))


def run_predictions(genaspen_root: Path, output_dir: Path, model_name: str,
                    model_file: Path, runtime_model: dict, power_model: dict,
                    wavefront_size: int, uv: str) -> tuple[list[dict], list[dict]]:
    stdout_dir = output_dir / "raw_stdout"
    stderr_dir = output_dir / "raw_stderr"
    staged_dir = output_dir / "staged_application_models"
    stdout_dir.mkdir(parents=True, exist_ok=True)
    stderr_dir.mkdir(parents=True, exist_ok=True)
    staged_dir.mkdir(parents=True, exist_ok=True)

    original_apps = {}
    original_hashes = {}
    for kernel in KERNELS:
        kernel_dir = genaspen_root / "kernels" / kernel
        app_path = kernel_dir / "app.aspen"
        original_apps[kernel] = app_path.read_text(encoding="utf-8")
        original_hashes[kernel] = sha256(app_path)
        (staged_dir / f"{kernel}.generated.aspen").write_text(
            original_apps[kernel], encoding="utf-8"
        )
        relative_model = Path("../../aspen/models/machine/sockets") / model_file.name
        mach = (
            f"    include {relative_model.as_posix()}\n"
            "    machine Machine{\n"
            "        node [1] Node\n"
            "    }\n"
            "    node Node{\n"
            "        socket [1] amd_mi300a\n"
            "    }\n"
        )
        (kernel_dir / "mach.aspen").write_text(mach, encoding="utf-8")

    rows = []
    commands = []
    for kernel in KERNELS:
        app_path = genaspen_root / "kernels" / kernel / "app.aspen"
        for n in TARGET_SIZES:
            app_path.write_text(original_apps[kernel], encoding="utf-8")
            command = [
                uv, "run", "--no-sync", "kernels/run_kernel_size_energy.py",
                "--aspen", "--reuse", "-f", "-l", "-s", "-r", "-p",
                "--kernel", kernel, "-n", str(n), "-mach", model_name,
            ]
            started_at = utc_now()
            start = time.perf_counter()
            try:
                completed = subprocess.run(
                    command,
                    cwd=genaspen_root,
                    capture_output=True,
                    text=True,
                    timeout=120,
                    check=False,
                )
            finally:
                app_path.write_text(original_apps[kernel], encoding="utf-8")
            elapsed = time.perf_counter() - start
            stem = f"{kernel}_n_{n}"
            stdout_path = stdout_dir / f"{stem}.txt"
            stderr_path = stderr_dir / f"{stem}.txt"
            stdout_path.write_text(completed.stdout, encoding="utf-8")
            stderr_path.write_text(completed.stderr, encoding="utf-8")
            row = {
                "kernel": kernel,
                "n": n,
                "returncode": completed.returncode,
                "flops": parse_metric(completed.stdout, "flops"),
                "loads": parse_metric(completed.stdout, "loads"),
                "stores": parse_metric(completed.stdout, "stores"),
                "runtime": parse_metric(completed.stdout, "runtime"),
                "power_W": parse_metric(completed.stdout, "power_W"),
                "energy_J": parse_metric(completed.stdout, "energy_J"),
                "stdout": str(stdout_path),
                "stderr": str(stderr_path),
            }
            rows.append(row)
            commands.append({
                "kernel": kernel,
                "n": n,
                "started_at_utc": started_at,
                "ended_at_utc": utc_now(),
                "elapsed_seconds": elapsed,
                "command": command,
                "cwd": str(genaspen_root),
                "returncode": completed.returncode,
                "stdout": str(stdout_path),
                "stderr": str(stderr_path),
            })

    with (output_dir / "commands.jsonl").open("w", encoding="utf-8") as stream:
        for command in commands:
            stream.write(json.dumps(command) + "\n")
    write_csv(output_dir / "predictions.csv", rows)

    app_integrity = []
    for kernel in KERNELS:
        app_path = genaspen_root / "kernels" / kernel / "app.aspen"
        after = sha256(app_path)
        app_integrity.append({
            "kernel": kernel,
            "before_sha256": original_hashes[kernel],
            "after_sha256": after,
            "unchanged": after == original_hashes[kernel],
        })
    write_csv(output_dir / "application_model_integrity.csv", app_integrity)

    invalid = []
    required = ("flops", "loads", "stores", "runtime", "power_W", "energy_J")
    for row in rows:
        if row["returncode"] != 0:
            invalid.append({**row, "reason": "nonzero return code"})
            continue
        for metric in required:
            value = row[metric]
            if value is None or not math.isfinite(value) or (
                    metric in ("runtime", "power_W", "energy_J") and value <= 0):
                invalid.append({**row, "reason": f"invalid {metric}"})
                break
        if invalid and invalid[-1].get("kernel") == row["kernel"] and invalid[-1].get("n") == row["n"]:
            continue
        direct_runtime = (row["loads"] + row["stores"]) / runtime_model[
            "bandwidth_B_per_s"
        ] * 1000.0
        direct_power = power_from_features(
            power_model,
            row["n"] / wavefront_size,
            row["flops"], row["loads"], row["stores"], row["runtime"],
        )
        direct_energy = direct_runtime / 1000.0 * direct_power
        parity = (
            math.isclose(row["runtime"], direct_runtime, rel_tol=5e-5, abs_tol=1e-8)
            and math.isclose(row["power_W"], direct_power, rel_tol=5e-5, abs_tol=1e-6)
            and math.isclose(row["energy_J"], direct_energy, rel_tol=1e-4, abs_tol=1e-6)
        )
        if not parity:
            invalid.append({
                **row,
                "reason": "Python/C++ provisional-model parity check failed",
                "direct_runtime": direct_runtime,
                "direct_power_W": direct_power,
                "direct_energy_J": direct_energy,
            })
    if invalid:
        write_csv(output_dir / "invalid_predictions.csv", invalid)
        raise RuntimeError(f"{len(invalid)} invalid predictions; see invalid_predictions.csv")
    if not all(item["unchanged"] for item in app_integrity):
        raise RuntimeError("staged application models were not restored after prediction")
    write_json(output_dir / "run_summary.json", {
        "jobs": len(rows),
        "failed_jobs": 0,
        "missing_required_metrics": 0,
        "model_name": model_name,
        "machine_model_sha256": sha256(model_file),
    })
    return rows, commands


def evaluate(rows: list[dict], measurements: list[dict], output_dir: Path,
             runtime_model: dict, power_model: dict,
             wavefront_size: int) -> list[dict]:
    truth = {
        (row["kernel"], row["n"]): row
        for row in measurements if row["phase"] == "target"
    }
    comparisons = []
    feature_rows = []
    diagnostics = []
    for predicted in rows:
        actual = truth[(predicted["kernel"], predicted["n"])]
        comparison = {
            "kernel": predicted["kernel"],
            "n": predicted["n"],
            "actual_runtime_ms": actual["actual_runtime_ms"],
            "predicted_runtime_ms": predicted["runtime"],
            "actual_power_W": actual["actual_power_W"],
            "predicted_power_W": predicted["power_W"],
            "actual_energy_J": actual["actual_energy_J"],
            "predicted_energy_J": predicted["energy_J"],
            "runtime_ape_percent": 100.0 * abs(
                predicted["runtime"] / actual["actual_runtime_ms"] - 1.0
            ),
            "power_ape_percent": 100.0 * abs(
                predicted["power_W"] / actual["actual_power_W"] - 1.0
            ),
            "energy_ape_percent": 100.0 * abs(
                predicted["energy_J"] / actual["actual_energy_J"] - 1.0
            ),
            "stdout": predicted["stdout"],
        }
        comparisons.append(comparison)

        expected = {
            "flops": actual["flops"],
            "loads": actual["loads_bytes"],
            "stores": actual["stores_bytes"],
        }
        for feature, reference in expected.items():
            observed = predicted[feature]
            feature_rows.append({
                "kernel": predicted["kernel"],
                "n": predicted["n"],
                "feature": feature,
                "reference": reference,
                "predicted": observed,
                "absolute_error": abs(observed - reference),
                "relative_error_percent": (
                    None if reference == 0
                    else 100.0 * abs(observed / reference - 1.0)
                ),
                "exact_match": observed == reference,
            })

        static_runtime = (
            (actual["loads_bytes"] + actual["stores_bytes"])
            / runtime_model["bandwidth_B_per_s"] * 1000.0
        )
        scenarios = {
            "A_static_truth_measured_runtime": power_from_features(
                power_model, actual["warps"], actual["flops"],
                actual["loads_bytes"], actual["stores_bytes"],
                actual["actual_runtime_ms"],
            ),
            "B_static_truth_predicted_runtime": power_from_features(
                power_model, actual["warps"], actual["flops"],
                actual["loads_bytes"], actual["stores_bytes"], static_runtime,
            ),
            "C_genaspen_measured_runtime": power_from_features(
                power_model, predicted["n"] / wavefront_size,
                predicted["flops"], predicted["loads"], predicted["stores"],
                actual["actual_runtime_ms"],
            ),
            "D_genaspen_predicted_runtime": predicted["power_W"],
        }
        for scenario, power_w in scenarios.items():
            diagnostics.append({
                "kernel": predicted["kernel"],
                "n": predicted["n"],
                "scenario": scenario,
                "actual_power_W": actual["actual_power_W"],
                "predicted_power_W": power_w,
                "power_ape_percent": 100.0 * abs(
                    power_w / actual["actual_power_W"] - 1.0
                ),
            })

    write_csv(output_dir / "official_end_to_end_comparison.csv", comparisons)
    write_csv(output_dir / "feature_accuracy.csv", feature_rows)
    write_csv(output_dir / "power_error_decomposition.csv", diagnostics)

    summary = []
    for group in ("all", *KERNELS):
        selected = comparisons if group == "all" else [
            row for row in comparisons if row["kernel"] == group
        ]
        summary.append({
            "group": group,
            "points": len(selected),
            "runtime_mape_percent": float(np.mean([
                row["runtime_ape_percent"] for row in selected
            ])),
            "power_mape_percent": float(np.mean([
                row["power_ape_percent"] for row in selected
            ])),
            "energy_mape_percent": float(np.mean([
                row["energy_ape_percent"] for row in selected
            ])),
        })
    write_csv(output_dir / "mape_summary.csv", summary)
    write_json(output_dir / "evaluation_summary.json", {
        "status": "COMPLETE",
        "definition": "MAPE=mean(abs(predicted-actual)/actual)*100",
        "points": len(comparisons),
        "invalid_predictions": 0,
        "overall": summary[0],
    })
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
    parser.add_argument("--wavefront-size", required=True, type=int)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--uv", default="uv")
    args = parser.parse_args()
    root = args.output_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    timing_path = root / "timings" / "analysis_stages.jsonl"
    if args.wavefront_size not in (32, 64):
        raise ValueError(f"unexpected AMD wavefront size: {args.wavefront_size}")
    if set(TRAIN_SIZES) & set(TARGET_SIZES):
        raise RuntimeError("train and target sizes overlap")

    with timed_stage(timing_path, "parse_and_validate_measurements"):
        measurements = parse_measurements(args.measurement_log)
        add_static_features(measurements, args.wavefront_size)
        write_csv(root / "input_snapshot" / "measurement_summary.csv", measurements)
        shutil.copy2(args.measurement_log,
                     root / "input_snapshot" / args.measurement_log.name)

    with timed_stage(timing_path, "collect_generation_tokens_and_time"):
        generation_summary = collect_generation_metrics(
            args.genaspen_root / "result_agentic_workflow" / "generation_debug",
            root / "generation",
        )

    train = [row for row in measurements if row["phase"] == "train"]
    with timed_stage(timing_path, "fit_type0_runtime_bandwidth"):
        runtime_model, runtime_fitted = fit_bandwidth(train)
        write_json(root / "training" / "runtime_model.json", runtime_model)

    with timed_stage(timing_path, "fit_type0_power_ridge"):
        power_model, power_fitted = fit_power(train)
        write_json(root / "training" / "power_model.json", power_model)
        fitted_rows = []
        for row, runtime_value, power_value in zip(
                train, runtime_fitted, power_fitted):
            fitted_rows.append({
                "kernel": row["kernel"],
                "n": row["n"],
                "actual_runtime_ms": row["actual_runtime_ms"],
                "fitted_runtime_ms": runtime_value,
                "runtime_ape_percent": 100.0 * abs(
                    runtime_value / row["actual_runtime_ms"] - 1.0
                ),
                "actual_power_W": row["actual_power_W"],
                "fitted_power_W": power_value,
                "power_ape_percent": 100.0 * abs(
                    power_value / row["actual_power_W"] - 1.0
                ),
            })
        write_csv(root / "training" / "training_fitted_values.csv", fitted_rows)
        combined_model = {
            "model_type": 0,
            "system": "Sirius AMD MI300A",
            "training_kernels": list(KERNELS),
            "training_rows": len(train),
            "target_rows_held_out": 9,
            "train_sizes": list(TRAIN_SIZES),
            "target_sizes": list(TARGET_SIZES),
            "execution_group": "wavefront",
            "wavefront_size": args.wavefront_size,
            "runtime": runtime_model,
            "power": power_model,
            "measurement_log_sha256": sha256(args.measurement_log),
            "base_machine_sha256": sha256(args.base_machine),
        }
        write_json(root / "training" / "type0_model.json", combined_model)

    model_name = "amd_mi300a_sirius_type0_axpy_copy_dot"
    with timed_stage(timing_path, "build_provisional_machine_model"):
        machine_dir = root / "machine_models"
        before_path = machine_dir / "before" / args.base_machine.name
        provisional_archive = machine_dir / "provisional" / f"{model_name}.aspen"
        before_path.parent.mkdir(parents=True, exist_ok=True)
        provisional_archive.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.base_machine, before_path)
        updated, parameter_block = build_machine_model(
            args.base_machine.read_text(encoding="utf-8"),
            runtime_model,
            power_model,
            args.wavefront_size,
        )
        provisional_archive.write_text(updated, encoding="utf-8")
        live_model = (
            args.genaspen_root / "aspen" / "models" / "machine" / "sockets"
            / f"{model_name}.aspen"
        )
        live_model.write_text(updated, encoding="utf-8")
        (machine_dir / "parameter_block.aspen").write_text(
            parameter_block, encoding="utf-8"
        )
        diff = "".join(difflib.unified_diff(
            args.base_machine.read_text(encoding="utf-8").splitlines(True),
            updated.splitlines(True),
            fromfile=str(args.base_machine),
            tofile=f"{model_name}.aspen",
        ))
        (machine_dir / "diffs").mkdir(parents=True, exist_ok=True)
        (machine_dir / "diffs" / "base_to_provisional.diff").write_text(
            diff, encoding="utf-8"
        )

    uv = shutil.which(args.uv) or args.uv
    with timed_stage(timing_path, "official_uv_predictions_9_points"):
        predictions, commands = run_predictions(
            args.genaspen_root,
            root / "predictions",
            model_name,
            live_model,
            runtime_model,
            power_model,
            args.wavefront_size,
            uv,
        )

    with timed_stage(timing_path, "evaluate_target_mape"):
        summary = evaluate(
            predictions,
            measurements,
            root / "evaluation",
            runtime_model,
            power_model,
            args.wavefront_size,
        )

    overall = summary[0]
    execution_log = f"""# Type0 axpy/copy/dot execution log

- Status: COMPLETE
- Completed (UTC): {utc_now()}
- System: Sirius / AMD MI300A
- Wavefront size detected at runtime: {args.wavefront_size}
- Training rows: 21 (target rows excluded)
- Validation rows: 9
- Runtime bandwidth: {runtime_model['bandwidth_GB_per_s']:.9g} GB/s
- Runtime train MAPE: {runtime_model['train_mape_percent']:.6g}%
- Power Ridge alpha: {power_model['alpha']:.9g}
- Power train MAPE: {power_model['train_mape_percent']:.6g}%
- LLM prompt tokens: {generation_summary['prompt_tokens']}
- LLM completion tokens: {generation_summary['completion_tokens']}
- LLM stage elapsed total: {generation_summary['elapsed_seconds']:.6f} s
- Target runtime MAPE (9 points): {overall['runtime_mape_percent']:.6g}%
- Target power MAPE (9 points): {overall['power_mape_percent']:.6g}%
- Target energy MAPE (9 points): {overall['energy_mape_percent']:.6g}%
- Base machine SHA-256: {sha256(before_path)}
- Provisional machine SHA-256: {sha256(provisional_archive)}

The canonical `/work/CSPP/ohara_803/genaspen` tree and its MI300A machine
model were not modified.  Generation and prediction used a PBS-job-local copy.
All nine official values came from saved `uv run --no-sync
kernels/run_kernel_size_energy.py --aspen --reuse ...` stdout files.
"""
    (root / "EXECUTION_LOG.md").write_text(execution_log, encoding="utf-8")
    write_manifest(root)
    result = {
        "status": "COMPLETE",
        "runtime_model": runtime_model,
        "power_model": {
            key: power_model[key]
            for key in ("alpha", "intercept", "coefficients",
                        "train_mape_percent", "leave_one_size_out_mape_percent")
        },
        "generation": generation_summary,
        "target_mape": overall,
        "prediction_commands": len(commands),
        "output_dir": str(root),
    }
    print(json.dumps(result, indent=2))
    print("TYPE0_EXPERIMENT_SUCCESS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
