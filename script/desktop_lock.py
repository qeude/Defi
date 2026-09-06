#!/usr/bin/env python3
"""Reserve this user's desktop across Defi worktrees and child commands."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sys
import time

LOCK_PATH = Path.home() / "Library/Caches/Defi/desktop-verification.lock"
LOCK_ENV = "DEFI_DESKTOP_LOCK_FD"


def inherited_lock(path=LOCK_PATH):
    try:
        fd = int(os.environ[LOCK_ENV])
        held, expected = os.fstat(fd), path.stat()
        if (held.st_dev, held.st_ino) == (expected.st_dev, expected.st_ino):
            return fd
    except (KeyError, ValueError, OSError):
        pass
    return None


def acquire(path=LOCK_PATH, wait=False):
    inherited = inherited_lock(path)
    if inherited is not None:
        return inherited
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
    except BlockingIOError:
        owner = os.read(fd, 4096).decode(errors="replace").strip()
        os.close(fd)
        raise BlockingIOError("Desktop busy: " + (owner or str(path)))
    os.ftruncate(fd, 0)
    os.write(fd, json.dumps({"pid": os.getpid(), "cwd": os.getcwd(), "acquired_at": time.time(),
                            "report": os.environ.get("DEFI_VERIFICATION_REPORT")}).encode())
    os.set_inheritable(fd, True)
    os.environ[LOCK_ENV] = str(fd)
    # Keep this inode: unlinking a locked file would let another process bypass it.
    return fd


def owner(path=LOCK_PATH):
    """Read current ownership, ignoring metadata left by a released lock."""
    try:
        with path.open("r+") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return None
            except BlockingIOError:
                return json.load(stream)
    except FileNotFoundError:
        return None
    except ValueError:
        return {"status": "acquiring"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.check:
        return 0 if inherited_lock() is not None else 1
    if not args.command:
        parser.error("provide a command, e.g. --wait bash for an interactive reservation")
    try:
        acquire(wait=args.wait)
    except BlockingIOError as error:
        print(error, file=sys.stderr)
        return 75
    os.execvp(args.command[0], args.command)


if __name__ == "__main__":
    sys.exit(main())
