"""Unix-socket client shared by the desktop diagnostic scripts."""

import glob
import json
import os
import socket


def find_socket():
    candidates = (
        glob.glob("/tmp/defi-*.sock")
        + glob.glob("/var/folders/*/*/T/defi-*.sock")
        + glob.glob(os.path.join(os.environ.get("TMPDIR", ""), "defi-*.sock"))
    )
    live = [path for path in candidates if os.path.exists(path)]
    if not live:
        raise SystemExit("defi socket not found")
    return max(live, key=os.path.getmtime)


class Connection:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(path)
            self.file = self.sock.makefile("rb")
        except OSError:
            self.sock.close()
            raise

    def command(self, command):
        payload = json.dumps({"command": command, "monitorIndex": None})
        self.sock.sendall((payload + "\n").encode())
        line = self.file.readline()
        return json.loads(line) if line else {"ok": False, "message": "eof"}

    def close(self):
        self.file.close()
        self.sock.close()
