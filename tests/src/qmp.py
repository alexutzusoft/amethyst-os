"""Minimal QMP client over localhost TCP for QEMU monitor interaction."""

import json
import socket
import time


def pick_free_port():
    """Pick an available ephemeral port on localhost."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class QMP:
    """Minimal QMP client for communicating with a QEMU instance."""

    def __init__(self, port, connect_timeout=15.0):
        deadline = time.time() + connect_timeout
        self.sock = None
        while self.sock is None:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
            except OSError:
                if time.time() > deadline:
                    raise TimeoutError(f"could not connect to QMP on port {port}")
                time.sleep(0.1)
        self.sock.settimeout(10.0)
        self._buf = b""
        self._recv()  # consume the QMP greeting
        self.execute("qmp_capabilities")

    def _recv(self):
        while b"\n" not in self._buf:
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("QMP connection closed")
            self._buf += data
        line, self._buf = self._buf.split(b"\n", 1)
        return json.loads(line)

    def _recv_result(self):
        # Skip asynchronous events; return the first command result/error.
        while True:
            msg = self._recv()
            if "return" in msg or "error" in msg:
                return msg

    def execute(self, command, **arguments):
        req = {"execute": command}
        if arguments:
            req["arguments"] = arguments
        self.sock.sendall((json.dumps(req) + "\n").encode())
        resp = self._recv_result()
        if "error" in resp:
            raise RuntimeError(f"QMP error for {command}: {resp['error']}")
        return resp["return"]

    def hmp(self, command_line):
        """Run a human-monitor command and return its text output."""
        return self.execute("human-monitor-command", **{"command-line": command_line})

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
