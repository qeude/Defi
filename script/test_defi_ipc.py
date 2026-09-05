"""Run with python3 script/test_defi_ipc.py; no desktop or daemon required."""

import json
import socket
import tempfile
import threading
from pathlib import Path

from defi_ipc import Connection


def check_connection():
    with tempfile.TemporaryDirectory() as directory:
        path = str(Path(directory) / "test.sock")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(path)
            server.listen(1)
            failures = []

            def respond():
                try:
                    with server.accept()[0] as peer, peer.makefile("rb") as stream:
                        for command in ["status", "list-workspaces", "quit"]:
                            assert json.loads(stream.readline()) == {"command": command, "monitorIndex": None}
                            if command == "quit":
                                break
                            peer.sendall(b'{"ok":true,')
                            peer.sendall(b'"message":"ready"}\n')
                except Exception as error:
                    failures.append(error)

            worker = threading.Thread(target=respond)
            worker.start()
            connection = Connection(path)
            try:
                assert connection.command("status") == {"ok": True, "message": "ready"}
                assert connection.command("list-workspaces")["ok"]
                assert connection.command("quit") == {"ok": False, "message": "eof"}
            finally:
                connection.close()
                worker.join(timeout=5)
            assert not worker.is_alive()
            assert not failures, failures
            assert connection.file.closed and connection.sock.fileno() == -1


if __name__ == "__main__":
    check_connection()
    print("IPC client: persistent replies, framing, EOF and cleanup passed")
