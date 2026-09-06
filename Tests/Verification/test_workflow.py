#!/usr/bin/env python3
"""Offline checks for verification isolation, contention, and result reporting."""
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))
import desktop_lock
import verify
import desktop_session


class WorkflowTests(unittest.TestCase):
    def test_lock_excludes_other_worktrees_and_survives_nested_exec(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "desktop.lock"
            program = "import sys; from pathlib import Path; import desktop_lock; desktop_lock.acquire(Path(sys.argv[1])); print('locked', flush=True); input()"
            env = dict(os.environ, PYTHONPATH=str(ROOT / "script"))
            env.pop(desktop_lock.LOCK_ENV, None)
            owner = subprocess.Popen([sys.executable, "-c", program, str(path)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
            waiter = None
            try:
                self.assertEqual(owner.stdout.readline().strip(), "locked")
                self.assertEqual(desktop_lock.owner(path)["pid"], owner.pid)
                contender = subprocess.run([sys.executable, "-c",
                    "from pathlib import Path; import desktop_lock; desktop_lock.acquire(Path(" + repr(str(path)) + "))"],
                    cwd=directory, env=env, capture_output=True, text=True)
                self.assertNotEqual(contender.returncode, 0)
                self.assertIn("Desktop busy", contender.stderr)
                waiter = subprocess.Popen([sys.executable, "-c",
                    "import sys; from pathlib import Path; import desktop_lock; print('waiting', flush=True); "
                    "desktop_lock.acquire(Path(sys.argv[1]), wait=True); print('acquired', flush=True)", str(path)],
                    cwd=directory, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                self.assertEqual(waiter.stdout.readline().strip(), "waiting")
                with self.assertRaises(subprocess.TimeoutExpired):
                    waiter.wait(timeout=0.1)
            finally:
                owner.communicate("\n", timeout=5)
                if waiter is not None:
                    stdout, stderr = waiter.communicate(timeout=5)
                    self.assertEqual(waiter.returncode, 0, stderr)
                    self.assertEqual(stdout.strip(), "acquired")
            # Kernel release after exit allows reuse of the same inode; no stale-lock cleanup.
            inode = path.stat().st_ino
            self.assertIsNone(desktop_lock.owner(path))
            previous = os.environ.pop(desktop_lock.LOCK_ENV, None)
            fd = desktop_lock.acquire(path)
            try:
                nested = subprocess.run([sys.executable, "-c",
                    "from pathlib import Path; import desktop_lock; print(desktop_lock.acquire(Path(" + repr(str(path)) + ")))"],
                    env=dict(os.environ, PYTHONPATH=str(ROOT / "script")), pass_fds=(fd,), capture_output=True, text=True)
                self.assertEqual(nested.returncode, 0, nested.stderr)
                self.assertEqual(int(nested.stdout), fd)
                self.assertEqual(path.stat().st_ino, inode)
            finally:
                os.close(fd)
                os.environ.pop(desktop_lock.LOCK_ENV, None)
                if previous is not None:
                    os.environ[desktop_lock.LOCK_ENV] = previous

    def test_local_never_enables_desktop_and_reports_failure_or_source_drift(self):
        for behavior, expected in [("pass", "passed"), ("fail", "failed"), ("drift", "invalidated")]:
            with self.subTest(behavior=behavior), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "script").mkdir()
                for name in ["verify.py", "desktop_lock.py"]:
                    shutil.copy2(ROOT / "script" / name, root / "script" / name)
                (root / "Tests/Verification").mkdir(parents=True)
                (root / "Tests/Verification/test_workflow.py").write_text("print('fixture workflow check')\n")
                (root / ".gitignore").write_text("dist/\nbin/\n__pycache__/\n")
                (root / "input.txt").write_text("original")
                for args in [["init", "-q"], ["add", "."], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Fixture"]]:
                    subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
                (root / "bin").mkdir()
                swift = root / "bin/swift"
                swift.write_text("#!/bin/sh\n[ \"$1\" = --version ] && { echo Fixture; exit 0; }\n[ \"$DEFI_E2E\" = 0 ] || exit 99\n" +
                    ("exit 3\n" if behavior == "fail" else "echo changed >> input.txt\n" if behavior == "drift" else "exit 0\n"))
                swift.chmod(0o755)
                result = subprocess.run([sys.executable, "script/verify.py", "local"], cwd=root,
                    env=dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"], DEFI_E2E="1"),
                    capture_output=True, text=True)
                report = json.loads(next((root / "dist/verification").glob("*/result.json")).read_text())
                self.assertEqual(report["status"], expected, result.stderr)
                self.assertEqual(result.returncode == 0, expected == "passed")
                self.assertTrue(all(Path(step["log"]).is_file() for step in report["steps"]))
                if behavior == "fail":
                    self.assertEqual(len(report["steps"]), 1)

    def test_desktop_rechecks_after_wait_before_installing(self):
        for mutation in ["none", "source", "bundle"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bundle = root / "Defi.app"
                bundle.mkdir()
                binary = bundle / "binary"
                binary.write_text("original")
                source = {"sha256": "original"}
                (root / "result.json").write_text(json.dumps({
                    "status": "passed", "mode": "local", "root": str(root),
                    "source": source, "bundle": str(bundle), "bundle_sha256": verify.bundle_digest(bundle),
                }))
                steps = []
                def acquired(wait=False):
                    self.assertTrue(wait)
                    if mutation == "source":
                        source["sha256"] = "changed"
                    elif mutation == "bundle":
                        binary.write_text("changed")
                def step(name, *_):
                    steps.append(name)
                    if name == "install":
                        raise RuntimeError("Stop before real installation")
                previous_handler = verify.signal.getsignal(verify.signal.SIGTERM)
                try:
                    with patch.object(verify, "ROOT", root), \
                         patch.object(verify, "source_identity", side_effect=lambda: dict(source)), \
                         patch.object(verify, "output", return_value="Fixture"), \
                         patch.object(verify, "acquire", side_effect=acquired) as lock, \
                         patch.object(verify, "run_step", side_effect=step), \
                         patch.object(sys, "argv", ["verify.py", "desktop", str(root), "--wait"]):
                        self.assertEqual(verify.main(), 1)
                        lock.assert_called_once_with(wait=True)
                finally:
                    verify.signal.signal(verify.signal.SIGTERM, previous_handler)
                report = json.loads(next((root / "dist/verification").glob("*/result.json")).read_text())
                self.assertEqual(steps, ["prepare-tests", "checkpoint", "install"] if mutation == "none" else ["prepare-tests"])
                self.assertEqual(report["status"], "failed" if mutation == "none" else "invalidated")
                self.assertIn("desktop_wait_seconds", report)

    def test_skips_and_failures_remain_distinct_from_passes(self):
        log = "\n".join(
            f"Test Case 'case-{i}' started.\nTest Case 'case-{i}' {state} (0.001 seconds)."
            for i, state in enumerate(["passed", "skipped", "failed"])
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.xml"
            self.assertEqual(verify.desktop_counts(log, path), {"tests": 3, "skipped": 1, "failed": 1})
            self.assertIn("<skipped", path.read_text())
        self.assertEqual(verify.desktop_counts("")["tests"], 0)
        with self.assertRaises(RuntimeError):
            verify.desktop_counts("Test Case 'truncated' started.")

    def test_full_prepares_then_enters_desktop_and_publishes_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phases = []
            def step(name, command, run, report, env=None):
                phases.append(name)
                if name == "stage":
                    bundle = Path(env["DEFI_STAGING_ROOT"]) / "Defi.app"
                    bundle.mkdir(parents=True)
                    (bundle / "binary").write_text("signed fixture")
                elif name == "checkpoint":
                    live = json.loads((run / "result.json").read_text())
                    self.assertEqual(live["status"], "running")
                    self.assertEqual(live["phase"], "waiting-desktop")
                    self.assertEqual(live["preparation"], "passed")
                    raise RuntimeError("Stop before desktop mutations")
            previous_handler = verify.signal.getsignal(verify.signal.SIGTERM)
            try:
                with patch.object(verify, "ROOT", root), \
                     patch.object(verify, "source_identity", return_value={"sha256": "unchanged"}), \
                     patch.object(verify, "output", return_value="Fixture"), \
                     patch.object(verify, "acquire") as lock, \
                     patch.object(verify, "run_step", side_effect=step), \
                     patch.object(sys, "argv", ["verify.py", "full"]):
                    self.assertEqual(verify.main(), 1)
                    lock.assert_called_once_with(wait=True)
            finally:
                verify.signal.signal(verify.signal.SIGTERM, previous_handler)
            self.assertEqual(phases, ["build", "tests", "workflow-tests", "stage", "prepare-tests", "checkpoint"])

    def test_failed_install_recovers_old_bundle_and_service(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            installed = root / "Applications/Defi.app"
            staged = root / "staged.app"
            for bundle, version in [(installed, "old"), (staged, "broken")]:
                macos = bundle / "Contents/MacOS"
                macos.mkdir(parents=True)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.quentin.defi"}))
                (bundle / "version").write_text(version)
                cli = macos / "defi"
                cli.write_text("#!/bin/sh\n"
                    'if [ "$1 $2" = "service stop" ]; then rm -f "$HOME/running"; exit 0; fi\n'
                    'if [ "$1 $2" = "service start" ]; then\n' +
                    ('exit 3\n' if version == "broken" else 'touch "$HOME/running"; exit 0\n') +
                    'fi\n[ "$1" = status ] && [ -f "$HOME/running" ]\n')
                cli.chmod(0o755)
            (root / "running").touch()
            binaries = root / "bin"
            binaries.mkdir()
            programs = {
                "codesign": "#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
                    "for a in sys.argv:\n if a.startswith('--extract-certificates='): Path(a.split('=',1)[1]+'0').write_text('same-cert')\n"
                    "if '-dr' in sys.argv: print('designated => same-requirement')\n",
                "pgrep": '#!/bin/sh\n[ -f "$HOME/running" ] && echo 123\n',
                "pkill": '#!/bin/sh\nrm -f "$HOME/running"\n',
                "ditto": '#!/usr/bin/env python3\nimport shutil,sys\nshutil.copytree(sys.argv[1],sys.argv[2])\n',
            }
            for name, program in programs.items():
                path = binaries / name
                path.write_text(program)
                path.chmod(0o755)
            env = dict(os.environ, HOME=str(root), PATH=str(binaries) + os.pathsep + os.environ["PATH"])
            env.pop(desktop_lock.LOCK_ENV, None)
            result = subprocess.run([str(ROOT / "script/build_and_run.sh"), "--install-staged", str(staged), "--verify"],
                                    env=env, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("restoring the previous bundle", result.stderr)
            self.assertEqual((installed / "version").read_text(), "old")
            self.assertTrue((root / "running").exists())
            self.assertFalse(list((root / "Applications").glob(".Defi-install.*")))

    def test_session_restore_reinstates_stores_and_checks_all_monitors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            saved, state = root / "checkpoint", root / "state"
            saved.mkdir()
            state.mkdir()
            topology = {"sessionID": "same", "topology": {"monitors": [{"id": 1, "workspaces": [{"width": 0.8}]}]}}
            for path in [saved, state]:
                (path / "workspace-topology.json").write_text(json.dumps(topology))
                (path / "placements.json").write_text('{}')
            (saved / "ready").touch()
            (saved / "status.txt").write_text('focused=42')
            (saved / "workspaces.json").write_text('{"monitors": []}')
            (state / "placements.json").write_text('{"changed": true}')
            with patch.object(desktop_session, "STATE", state), \
                 patch.object(desktop_session, "stop") as stop, \
                 patch.object(desktop_session, "start") as start, \
                 patch.object(desktop_session, "daemon_count", return_value=1), \
                 patch.object(desktop_session.time, "sleep"), \
                 patch.object(desktop_session, "command", return_value='focused=42 drift=0[] focusPending=false axPending=false'):
                desktop_session.restore(saved)
                stop.assert_called_once()
                start.assert_called_once()
                self.assertEqual((state / "placements.json").read_text(), '{}')
                self.assertTrue((saved / 'restored-topology.json').exists())
            self.assertFalse(desktop_session.close_enough([{"width": 1}], [{"width": 0.8}]))
            self.assertFalse(desktop_session.close_enough([{"id": 1}], [{"id": 2}]))

    def test_signing_requires_same_certificate_and_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            installed, staged = root / "installed", root / "staged"
            installed.mkdir()
            staged.mkdir()
            fake = root / "codesign"
            fake.write_text("#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\np=Path(sys.argv[-1])\nfor arg in sys.argv:\n if arg.startswith('--extract-certificates='):\n  Path(arg.split('=',1)[1]+'0').write_bytes((p/'certificate').read_bytes())\nif '-dr' in sys.argv: print('designated => '+(p/'requirement').read_text())\n")
            fake.chmod(0o755)
            (installed / "certificate").write_text("certificate-A")
            (installed / "requirement").write_text("requirement-A")
            for certificate, requirement, expected in [
                ("certificate-A", "requirement-A", 0),
                ("certificate-B", "requirement-A", 1),
                ("certificate-A", "requirement-B", 1),
            ]:
                (staged / "certificate").write_text(certificate)
                (staged / "requirement").write_text(requirement)
                result = subprocess.run([str(ROOT / "script/check_signing.sh"), str(installed), str(staged)],
                    env=dict(os.environ, PATH=str(root)+os.pathsep+os.environ["PATH"]), capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_invalid_build_mode_fails_before_build_or_install(self):
        result = subprocess.run([str(ROOT / "script/build_and_run.sh"), "--typo"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
