#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Summarize timeout snapshots; frozen switch-time counters are inconclusive."""
import argparse, json, re
from pathlib import Path


def summarize(path):
    works = {}
    current = None
    snapshot = None
    for line in Path(path).read_text(errors="replace").splitlines():
        m = re.search(r"G16: (?:hang flight|pending|quarantined compute) Work=(0x[0-9a-f]+) context=(\d+)", line)
        if m:
            current = works.setdefault(m[1], {"work": m[1], "context": int(m[2]), "reports": [], "compute_samples": []})
            current["reports"].append(line)
            snapshot = None
        elif "G16: async Work" in line:
            current = snapshot = None
        elif current and "G16: compute queue=" in line:
            fields = dict(re.findall(r"(\w+)=(0x[0-9a-f]+|[0-9]+/[0-9]+)", line))
            snapshot = {"line": line, **fields}
            current["compute_samples"].append(snapshot)
        elif snapshot and "G16: compute support=" in line:
            snapshot["support_line"] = line
        elif snapshot and "G16: compute record words" in line:
            snapshot["record_words"] = re.findall(r"0x[0-9a-f]+", line)
    for work in works.values():
        samples = work["compute_samples"]
        runtime = {s.get("runtime") for s in samples}
        records = {tuple(s["record_words"]) for s in samples if "record_words" in s}
        work["runtime_changes"] = max(0, len(runtime) - 1)
        work["record_changes"] = max(0, len(records) - 1)
        work["progress_evidence"] = ("sampled fields changed; correlate lane scheduling and Work identity"
            if len(runtime) > 1 or len(records) > 1 else
            "no sampled change; cannot distinguish continuous execution from an unscheduled lane")
    return {"source": str(path), "works": list(works.values())}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel_log", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.kernel_log), indent=2))
