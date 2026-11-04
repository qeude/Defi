#!/usr/bin/env python3
"""Generates the mutation catalog: one realistic bug per row, labeled by bug type and area.

Each operator rewrites one line of Swift. A row is kept only when its original line is unique in
its file, so script/mutate.sh can plant it by exact replacement. Whether a mutant compiles is
checked when it runs; rows that do not compile are reported and skipped, never counted.

    generate.py [--out Tests/Mutation/catalog.tsv]
"""
import argparse
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ["Sources/DefiCore", "Sources/DefiRuntime", "Sources/DefiMacOS", "Sources/DefiDaemon"]

# Bug types the loop must catch (docs/testing/mutation.md defines each one).
TYPES = [
    "lag", "delay", "glitch", "flicker", "unexpected", "permission", "animation",
    "stale-write", "oscillation", "multi-display", "lost-input", "hang",
]

# Files whose code is UI drawing only; mutants there need real pixels to observe.
DRAWING = re.compile(r"(View|Scene|Panel|Overlay|Renderer|Settings|Cheatsheet|AppUpdater|MenuBar|Capture|Preview|Icon|Glass|Spacing)")


def area(path: str) -> str:
    name = Path(path).name
    for pattern, label in [
        (r"Focus|UserInput|HotKey|Cursor|Pointer", "focus"),
        (r"Frame|Settlement|WindowBorder|Border", "frames"),
        (r"Snapshot|Discovery|Observation|EventMonitor|EventNormal|Classification|Platform\.swift", "discovery"),
        (r"Parking|ContinuousStrip|Visibility", "parking"),
        (r"Monitor|Display|Staircase|Reserved", "displays"),
        (r"Mouse|Drag|Drop", "mouse"),
        (r"Overview", "overview"),
        (r"Animation|Ribbon|Scroll", "animation"),
        (r"Permission|ScreenRecording|Accessibility", "permissions"),
    ]:
        if re.search(pattern, name):
            return label
    return "layout" if "DefiCore" in path or "DefiRuntime" in path else "daemon"


def context_type(path: str, line: str, default: str) -> str:
    """The bug a generic rewrite of this line produces, judged by where it sits."""
    low = line.lower()
    name = Path(path).name
    if re.search(r"generation|iscurrent|superseded|stale", low):
        return "stale-write"
    if re.search(r"trusted|granted|preflight|permission|screenrecording", low):
        return "permission"
    if re.search(r"animat|timeline|duration|interpolat", low):
        return "animation"
    if re.search(r"retry|backoff|followup|attempt|while ", low):
        return "hang" if "while " in low else "oscillation"
    if area(path) == "displays" or re.search(r"otherdisplays|staircase|displayframe|physicalframe|monitorframes", low):
        return "multi-display"
    if area(path) == "parking" or re.search(r"park|hidden|visib|sliver", low):
        return "flicker"
    if "HotKeys" in name or re.search(r"capturedkey|bindings\[|keyboardcaptured|deliver\(", low):
        return "lost-input"
    if area(path) == "frames":
        return "glitch"
    return default



OPERATORS = [
    ("flip-lt", "unexpected", re.compile(r"(?<=\s)<(?=\s)"), "<="),
    ("flip-le", "unexpected", re.compile(r"(?<=\s)<=(?=\s)"), "<"),
    ("flip-gt", "unexpected", re.compile(r"(?<=\s)>(?=\s)"), ">="),
    ("flip-ge", "unexpected", re.compile(r"(?<=\s)>=(?=\s)"), ">"),
    ("flip-eq", "unexpected", re.compile(r"(?<=\s)==(?=\s)"), "!="),
    ("flip-ne", "unexpected", re.compile(r"(?<=\s)!=(?=\s)"), "=="),
    ("off-by-one-plus", "unexpected", re.compile(r" \+ 1\b"), " + 2"),
    ("off-by-one-minus", "unexpected", re.compile(r" - 1\b"), ""),
    ("drop-and", "unexpected", re.compile(r" && [^&|{}]+?(?=\s*(\{|,|\)|$))"), ""),
    ("drop-or", "unexpected", re.compile(r" \|\| [^&|{}]+?(?=\s*(\{|,|\)|$))"), ""),
    ("return-true", "unexpected", re.compile(r"\breturn true\b"), "return false"),
    ("return-false", "unexpected", re.compile(r"\breturn false\b"), "return true"),
    ("assign-true", "unexpected", re.compile(r"= true\b"), "= false"),
    ("assign-false", "unexpected", re.compile(r"= false\b"), "= true"),
    ("negate-guard", "unexpected", re.compile(r"\bguard !"), "guard "),
]

DELAY_LINE = re.compile(r"after\(|asyncAfter|[Tt]imeout|[Dd]elay|Interval|\.milliseconds\(|\.seconds\(|sleep\(")
NUMBER = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?|\d+_\d+)(?![\w.])")
CALL_STATEMENT = re.compile(r"^\s*(self\.)?[a-zA-Z_][\w.]*\??\.[a-zA-Z_]\w*\(.*\)\s*$|^\s*[a-z]\w*\(.*\)\s*$")


def mutants_for_line(path: str, line: str):
    stripped = line.strip()
    if not stripped or stripped.startswith("//") or '"' in line or stripped.startswith(("import ", "case ", "@")):
        return
    for name, default, pattern, replacement in OPERATORS:
        if pattern.search(line):
            mutated = pattern.sub(replacement, line, count=1)
            if mutated != line:
                yield name, context_type(path, line, default), mutated
    # Delays and timeouts ten times longer: late convergence, or lag on the input path.
    if DELAY_LINE.search(line):
        match = NUMBER.search(line)
        if match and float(match.group(1).replace("_", "")) > 0:
            value = match.group(1)
            scaled = f"({value} * 10)"
            mutated = line[: match.start()] + scaled + line[match.end():]
            kind = "lag" if re.search(r"HotKeys|AXFocus|Input", Path(path).name) or "timeout" in line.lower() else "delay"
            yield "delay-x10", kind, mutated
    # Commands delivered late from the event tap: work queued behind the input path.
    if "HotKeys" in Path(path).name and stripped == "NavigationActor.enqueue {":
        yield "input-latency", "lag", line.replace("NavigationActor.enqueue {", "DefiClock.after(0.25, on: NavigationActor.shared.queue) {")
    # Coalescing removed: every transient step is committed.
    if re.search(r"coalesc", line, re.I) and "&&" in line:
        yield "drop-coalescing", "lag", re.sub(r" && [^&|{}]+?(?=\s*(\{|,|\)|$))", "", line, count=1)
    # A statement call removed: a write, a notification or a cleanup that never happens.
    if CALL_STATEMENT.match(line) and not re.match(r"\s*(return|let|var|guard|if|try|await|defer|super)\b", line):
        indent = line[: len(line) - len(line.lstrip())]
        yield "drop-call", context_type(path, line, "unexpected"), f"{indent}()"
    # A write statement issued twice: a window placed in two steps.
    if area(path) == "frames" and CALL_STATEMENT.match(line) and re.search(r"[Ww]rite|apply|commit|submit", line):
        yield "double-write", "glitch", f"{line}; {stripped}"


def generate():
    rows = []
    for target in TARGETS:
        for file in sorted((ROOT / target).rglob("*.swift")):
            rel = str(file.relative_to(ROOT))
            if DRAWING.search(file.name):
                continue
            lines = file.read_text().split("\n")
            counts = {}
            for line in lines:
                counts[line] = counts.get(line, 0) + 1
            for number, line in enumerate(lines, start=1):
                if counts[line] != 1:
                    continue
                for operator, kind, mutated in mutants_for_line(rel, line):
                    rows.append({
                        "id": f"{Path(rel).stem}:{number}:{operator}",
                        "type": kind, "area": area(rel), "operator": operator,
                        "file": rel, "line": number, "original": line, "replacement": mutated,
                        "description": f"{operator} at {Path(rel).name}:{number}",
                    })
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="Tests/Mutation/catalog.tsv")
    args = parser.parse_args()
    rows = generate()
    out = ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t", quoting=csv.QUOTE_NONE, escapechar="\\")
        writer.writeheader()
        writer.writerows(rows)
    by_type = {kind: sum(1 for row in rows if row["type"] == kind) for kind in TYPES}
    print(f"{len(rows)} mutants -> {args.out}", file=sys.stderr)
    print("  " + "  ".join(f"{kind}={count}" for kind, count in by_type.items()), file=sys.stderr)


if __name__ == "__main__":
    main()
