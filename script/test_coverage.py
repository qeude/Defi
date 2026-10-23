#!/usr/bin/env python3
"""Run the non-desktop tests with coverage and report line coverage per Sources module and file."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
# A separate scratch path keeps the instrumented build from invalidating the regular one.
SCRATCH = ROOT / ".build/coverage"


def summarize(export):
    modules, files = {}, {}
    for entry in export["data"][0]["files"]:
        path = Path(entry["filename"]).resolve()
        try:
            relative = path.relative_to(ROOT / "Sources")
        except ValueError:
            continue
        lines = entry["summary"]["lines"]
        files[str(relative)] = {"covered": lines["covered"], "count": lines["count"]}
        module = modules.setdefault(relative.parts[0], {"covered": 0, "count": 0})
        module["covered"] += lines["covered"]
        module["count"] += lines["count"]
    for item in [*modules.values(), *files.values()]:
        item["percent"] = round(100 * item["covered"] / item["count"], 2) if item["count"] else 100.0
    return {"modules": dict(sorted(modules.items())), "files": dict(sorted(files.items()))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/verification/coverage.json")
    parser.add_argument("--files", action="store_true", help="also print per-file coverage")
    args = parser.parse_args()
    env = dict(os.environ, DEFI_E2E="0")
    swift = ["swift", "test", "--scratch-path", str(SCRATCH)]
    subprocess.run([*swift, "--enable-code-coverage", "--skip", "DesktopE2ETests"], cwd=ROOT, env=env, check=True)
    codecov = Path(subprocess.check_output([*swift, "--show-codecov-path"], cwd=ROOT, env=env).decode().strip())
    profdata = codecov.parent / "default.profdata"
    # Each test target is its own bundle; llvm-cov merges the shared sources.
    objects = [arg for bundle in sorted(codecov.parent.parent.glob("*.xctest"))
               for arg in ("-object", str(bundle / "Contents/MacOS" / bundle.stem))]
    export = json.loads(subprocess.check_output(
        ["xcrun", "llvm-cov", "export", "-summary-only", "-instr-profile", str(profdata), *objects]))
    summary = summarize(export)
    summary["commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2) + "\n")
    rows = list(summary["modules"].items()) + (list(summary["files"].items()) if args.files else [])
    for name, item in rows:
        print(f"{item['percent']:7.2f}%  {item['covered']:6}/{item['count']:<6}  {name}")
    print("Coverage: " + str(args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
