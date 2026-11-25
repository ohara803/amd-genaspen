#!/usr/bin/env python3
"""Run one command while preserving output and a structured timing record."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", required=True)
    parser.add_argument("--timing-jsonl", required=True, type=Path)
    parser.add_argument("--stdout", required=True, type=Path)
    parser.add_argument("--stderr", required=True, type=Path)
    parser.add_argument("--cwd", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")

    args.stdout.parent.mkdir(parents=True, exist_ok=True)
    args.stderr.parent.mkdir(parents=True, exist_ok=True)
    args.timing_jsonl.parent.mkdir(parents=True, exist_ok=True)

    started_at = utc_now()
    start = time.perf_counter()
    completed = subprocess.run(
        command,
        cwd=args.cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.perf_counter() - start
    ended_at = utc_now()

    args.stdout.write_text(completed.stdout, encoding="utf-8")
    args.stderr.write_text(completed.stderr, encoding="utf-8")
    sys.stdout.write(completed.stdout)
    sys.stderr.write(completed.stderr)
    sys.stdout.flush()
    sys.stderr.flush()

    record = {
        "stage": args.stage,
        "started_at_utc": started_at,
        "ended_at_utc": ended_at,
        "elapsed_seconds": elapsed,
        "returncode": completed.returncode,
        "cwd": str(args.cwd.resolve()),
        "command": command,
        "stdout": str(args.stdout.resolve()),
        "stderr": str(args.stderr.resolve()),
    }
    with args.timing_jsonl.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + "\n")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
