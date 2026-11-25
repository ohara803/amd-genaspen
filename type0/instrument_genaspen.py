#!/usr/bin/env python3
"""Instrument a staged GenASPEN generator with per-LLM-stage wall times.

This script must only be pointed at a disposable copy.  It refuses to patch a
file unless every expected source fragment is present exactly once.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("generator", type=Path)
    args = parser.parse_args()

    path = args.generator.resolve()
    if "/work/CSPP/ohara_803/genaspen/" in path.as_posix():
        raise RuntimeError("refusing to modify the canonical GenASPEN tree")

    source = path.read_text(encoding="utf-8")
    source = replace_once(
        source,
        "import json\n",
        "import json\nimport time\n",
        "time import",
    )
    source = replace_once(
        source,
        "def save_generate_response(stage: str, attempt: int, response) -> None:",
        "def save_generate_response(\n"
        "        stage: str, attempt: int, response, elapsed_seconds: float\n"
        "    ) -> None:",
        "metadata function signature",
    )
    source = replace_once(
        source,
        '            "thinking_length": len(thinking_text),\n',
        '            "thinking_length": len(thinking_text),\n'
        '            "elapsed_seconds": elapsed_seconds,\n',
        "metadata elapsed field",
    )
    source = replace_once(
        source,
        "            json_response = client.generate(\n"
        "                model=\"gpt-oss:120b\",\n"
        "                prompt=generation_prompt,\n"
        "                system=json_ir_rules,\n"
        "                stream=False,\n"
        "                options=generation_options,\n"
        "            )\n"
        "            save_generate_response(\"json_ir\", attempt, json_response)\n",
        "            stage_started = time.perf_counter()\n"
        "            json_response = client.generate(\n"
        "                model=\"gpt-oss:120b\",\n"
        "                prompt=generation_prompt,\n"
        "                system=json_ir_rules,\n"
        "                stream=False,\n"
        "                options=generation_options,\n"
        "            )\n"
        "            stage_elapsed = time.perf_counter() - stage_started\n"
        "            save_generate_response(\n"
        "                \"json_ir\", attempt, json_response, stage_elapsed\n"
        "            )\n",
        "JSON IR generation timer",
    )
    source = replace_once(
        source,
        "        aspen_response = client.generate(\n"
        "            model=\"gpt-oss:120b\",\n"
        "            prompt=aspen_prompt,\n"
        "            system=aspen_rules,\n"
        "            stream=False,\n"
        "            options=generation_options,\n"
        "        )\n\n"
        "        save_generate_response(\"aspen\", 1, aspen_response)\n",
        "        stage_started = time.perf_counter()\n"
        "        aspen_response = client.generate(\n"
        "            model=\"gpt-oss:120b\",\n"
        "            prompt=aspen_prompt,\n"
        "            system=aspen_rules,\n"
        "            stream=False,\n"
        "            options=generation_options,\n"
        "        )\n"
        "        stage_elapsed = time.perf_counter() - stage_started\n\n"
        "        save_generate_response(\n"
        "            \"aspen\", 1, aspen_response, stage_elapsed\n"
        "        )\n",
        "ASPEN generation timer",
    )

    path.write_text(source, encoding="utf-8")
    print(f"instrumented staged generator: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
