#!/usr/bin/env python3
"""Build/test without the desktop, then verify a prepared bundle exclusively."""
import argparse
from collections import Counter
import hashlib
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

from desktop_lock import acquire, inherited_lock, owner

ROOT = Path(__file__).resolve().parent.parent


def save_report(directory, report):
    report["updated_at"] = time.time()
    temporary = directory / "result.json.tmp"
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(directory / "result.json")


def output(*args):
    return subprocess.check_output(args, cwd=ROOT).decode().strip()


def source_identity():
    digest = hashlib.sha256()
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    )
    for name in sorted(set(names.split(b"\0")) - {b""}):
        path = ROOT / os.fsdecode(name)
        digest.update(name + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest() if path.is_file() else b"missing")
    return {"commit": output("git", "rev-parse", "HEAD"), "sha256": digest.hexdigest()}


def bundle_digest(bundle):
    digest = hashlib.sha256()
    for path in sorted(bundle.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(bundle)).encode() + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def desktop_counts(log, xml_path=None):
    # SwiftPM's parallel xUnit writer reports skipped XCTest cases as passing.
    # Use serial XCTest case events and fail closed on missing completions.
    started = re.findall(r"^Test Case '(.+)' started\.$", log, re.MULTILINE)
    finished = re.findall(r"^Test Case '(.+)' (passed|failed|skipped) \(([0-9.]+) seconds\)\.$", log, re.MULTILINE)
    if Counter(started) != Counter(name for name, _, _ in finished):
        raise RuntimeError("Incomplete XCTest case events; inspect desktop-tests.log")
    counts = {"tests": len(finished), "skipped": sum(state == "skipped" for _, state, _ in finished),
              "failed": sum(state == "failed" for _, state, _ in finished)}
    if xml_path is not None:
        suite = ET.Element("testsuite", name="DesktopE2ETests", tests=str(counts["tests"]),
                           skipped=str(counts["skipped"]), failures=str(counts["failed"]))
        for name, state, seconds in finished:
            case = ET.SubElement(suite, "testcase", name=name, time=seconds)
            if state != "passed":
                ET.SubElement(case, "skipped" if state == "skipped" else "failure")
        ET.ElementTree(suite).write(xml_path, encoding="utf-8", xml_declaration=True)
    return counts


def run_step(name, command, directory, report, env=None):
    log = directory / (name + ".log")
    step = {"name": name, "command": [str(x) for x in command], "log": str(log)}
    report["steps"].append(step)
    step["status"] = "running"
    report.update(phase=name, phase_started_at=time.time())
    save_report(directory, report)
    started = time.monotonic()
    print(name + "… " + str(log), flush=True)
    fd = inherited_lock()
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True,
                                   pass_fds=() if fd is None else (fd,))
        try:
            code = process.wait()
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            step["status"] = "interrupted"
            raise
        finally:
            step["seconds"] = round(time.monotonic() - started, 3)
    step.update(exit_code=code, status="passed" if code == 0 else "failed")
    save_report(directory, report)
    if code:
        print("\n".join(log.read_text(errors="replace").splitlines()[-25:]), file=sys.stderr)
        raise RuntimeError(name + " failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    local = sub.add_parser("local", help="build and test without desktop mutations")
    local.add_argument("--stage", action="store_true", help="also prepare a signed bundle")
    desktop = sub.add_parser("desktop", help="install/test a successful local --stage run")
    desktop.add_argument("run", type=Path)
    desktop.add_argument("--filter", default="DesktopE2ETests")
    desktop.add_argument("--wait", action="store_true", help="wait for the desktop reservation instead of exiting 75")
    full = sub.add_parser("full", help="prepare, wait for the desktop, install, and test")
    full.add_argument("--filter", default="DesktopE2ETests")
    full.set_defaults(stage=True, wait=True)
    status = sub.add_parser("status", help="show live reports and the desktop owner")
    status.add_argument("run", type=Path, nargs="?")
    args = parser.parse_args()
    if args.mode == "status":
        paths = [args.run / "result.json"] if args.run else sorted(
            (ROOT / "dist/verification").glob("*/result.json"), reverse=True)[:10]
        reports = []
        for path in paths:
            report = json.loads(path.read_text())
            report["report"] = str(path.resolve())
            if report.get("phase_started_at") and report["status"] == "running":
                report["phase_seconds"] = round(time.time() - report["phase_started_at"], 1)
                try:
                    os.kill(report["pid"], 0)
                    report["process_alive"] = True
                except ProcessLookupError:
                    report["process_alive"] = False
            reports.append(report)
        print(json.dumps({"desktop_owner": owner(), "runs": reports}, indent=2))
        return 0
    directory = ROOT / "dist/verification" / (time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    report = {"mode": args.mode, "status": "running", "root": str(ROOT), "steps": [], "visual": "not-run",
              "pid": os.getpid(), "started_at": time.time(), "phase": "initializing"}
    manifest = directory / "result.json"
    print("Results: " + str(manifest), flush=True)
    save_report(directory, report)
    exit_code = 1
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        report["source"] = source_identity()
        report["swift"] = output("swift", "--version")
        if args.mode in ("local", "full"):
            env = dict(os.environ, DEFI_E2E="0")
            run_step("build", ["swift", "build"], directory, report, env)
            run_step("tests", ["swift", "test", "--skip", "DesktopE2ETests"], directory, report, env)
            run_step("workflow-tests", [sys.executable, "Tests/Verification/test_workflow.py"], directory, report, env)
            report["desktop"] = "not-run"
            if args.stage:
                env["DEFI_STAGING_ROOT"] = str(directory / "staged")
                run_step("stage", [str(ROOT / "script/build_and_run.sh"), "--stage"], directory, report, env)
                bundle = directory / "staged/Defi.app"
                report.update(bundle=str(bundle), bundle_sha256=bundle_digest(bundle))
            if source_identity() != report["source"]:
                report["status"] = "invalidated"
                raise RuntimeError("Source changed during preparation; rerun local --stage")
            report["preparation"] = "passed"
            save_report(directory, report)
        if args.mode in ("desktop", "full"):
            prepared = dict(report) if args.mode == "full" else json.loads((args.run / "result.json").read_text())
            valid_preparation = (prepared.get("mode") == "local" and prepared.get("status") == "passed") or (
                prepared.get("mode") == "full" and prepared.get("preparation") == "passed")
            if not valid_preparation or "bundle" not in prepared:
                raise RuntimeError("A successful local --stage run is required")
            if prepared.get("root") != str(ROOT) or prepared["source"] != report["source"]:
                raise RuntimeError("Source changed or belongs to another worktree; rerun local --stage")
            bundle = Path(prepared["bundle"])
            if not bundle.is_dir() or bundle_digest(bundle) != prepared["bundle_sha256"]:
                raise RuntimeError("Prepared bundle changed; rerun local --stage")
            if not args.filter.startswith("DesktopE2ETests"):
                raise RuntimeError("Desktop filter must start with DesktopE2ETests")
            report.update(prepared_run=str(directory if args.mode == "full" else args.run.resolve()), bundle=str(bundle),
                          bundle_sha256=prepared["bundle_sha256"], filter=args.filter)
            run_step("prepare-tests", ["swift", "build", "--build-tests"], directory, report)
            if source_identity() != report["source"]:
                raise RuntimeError("Source changed during preparation; rerun local --stage")
            if args.wait:
                print("Waiting for desktop reservation…", flush=True)
            waiting = time.monotonic()
            report.update(phase="waiting-desktop", phase_started_at=time.time())
            save_report(directory, report)
            os.environ["DEFI_VERIFICATION_REPORT"] = str(manifest)
            acquire(wait=args.wait)
            report["desktop_wait_seconds"] = round(time.monotonic() - waiting, 3)
            # Another writer may have changed this worktree while we waited.
            if source_identity() != report["source"]:
                report["status"] = "invalidated"
                raise RuntimeError("Source changed before desktop reservation; rerun local --stage")
            if not bundle.is_dir() or bundle_digest(bundle) != prepared["bundle_sha256"]:
                report["status"] = "invalidated"
                raise RuntimeError("Prepared bundle changed before desktop reservation; rerun local --stage")
            checkpoint = directory / "checkpoint"
            session = [sys.executable, str(ROOT / "script/desktop_session.py")]
            try:
                run_step("checkpoint", [*session, "checkpoint", str(checkpoint)], directory, report)
                run_step("install", [str(ROOT / "script/build_and_run.sh"), "--install-staged", str(bundle), "--verify"], directory, report)
                installed = Path.home() / "Applications/Defi.app"
                if bundle_digest(installed) != prepared["bundle_sha256"]:
                    raise RuntimeError("Installed bundle differs from the verified artifact")
                cli = installed / "Contents/MacOS/defi"
                try:
                    run_step("status-before", [str(cli), "status"], directory, report)
                    run_step("desktop-tests", [str(ROOT / "script/test_desktop.sh"), "--run-built-tests", args.filter], directory, report)
                finally:
                    log_path = directory / "desktop-tests.log"
                    log = log_path.read_text(errors="replace") if log_path.exists() else ""
                    report["accessibility"] = ("unavailable" if "DEFI_E2E accessibility=unavailable" in log else
                                               "available" if "DEFI_E2E accessibility=available" in log else "unknown")
                    try:
                        report["desktop"] = desktop_counts(log, directory / "desktop.xml")
                    except RuntimeError as error:
                        report["desktop_parse_error"] = str(error)
                    for name in ["status", "trace"]:
                        try:
                            run_step(name + "-after", [str(cli), name], directory, report)
                        except RuntimeError:
                            pass  # Preserve the test failure; diagnostics remain in the logs.
                counts = desktop_counts(log, directory / "desktop.xml")
                report["desktop"] = counts
                if not counts["tests"] or counts["skipped"] or counts["failed"]:
                    report["status"] = "incomplete"
                    raise RuntimeError("Desktop coverage incomplete: " + json.dumps(counts))
            finally:
                if (checkpoint / "ready").exists():
                    try:
                        run_step("restore-session", [*session, "restore", str(checkpoint)], directory, report)
                        report["restoration"] = "passed"
                    except (RuntimeError, OSError) as error:
                        report["restoration"] = "failed"
                        report["restoration_error"] = str(error)
                        raise
        if source_identity() != report["source"]:
            report["status"] = "invalidated"
            raise RuntimeError("Source changed during verification; results do not certify the current tree")
        if any(step.get("status") != "passed" for step in report["steps"]):
            raise RuntimeError("A verification or diagnostic step failed; inspect the logs")
        report["status"] = "passed"
        exit_code = 0
    except BlockingIOError as error:
        report.update(status="busy", error=str(error))
        print(str(error), file=sys.stderr)
        exit_code = 75
    except (RuntimeError, OSError, KeyError, ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        report["error"] = str(error)
        if report["status"] == "running":
            report["status"] = "failed"
        print(str(error), file=sys.stderr)
    except KeyboardInterrupt:
        report["status"] = "interrupted"
        exit_code = 130
    finally:
        save_report(directory, report)
        print(report["status"] + ": " + str(manifest), flush=True)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
