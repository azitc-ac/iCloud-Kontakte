"""Dieselben Flow-Tests gegen die PowerShell-Variante (Windows PowerShell 5.1)."""
import socket
import subprocess
import sys
import threading
import time
import unittest
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mock_carddav  # noqa: E402
import test_flow  # noqa: E402

PS1 = Path(__file__).resolve().parent.parent / "iCloud-Kontakte.ps1"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class PsFlow(test_flow.Flow):
    @classmethod
    def setUpClass(cls):
        cls.mock = mock_carddav.make_server(0, test_flow.COUNT)
        threading.Thread(target=cls.mock.serve_forever, daemon=True).start()
        port = free_port()
        cls.proc = subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(PS1), "-Port", str(port),
             "-NoBrowser", "-CardDavUrl", f"http://127.0.0.1:{cls.mock.server_address[1]}/"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        cls.base = f"http://127.0.0.1:{port}"
        cls.cookie = None
        for _ in range(100):
            try:
                urllib.request.urlopen(cls.base + "/", timeout=2)
                return
            except Exception:
                time.sleep(0.3)
        cls.proc.kill()
        raise RuntimeError("PowerShell-Server startet nicht: " + cls.proc.stdout.read().decode(errors="replace"))

    @classmethod
    def tearDownClass(cls):
        cls.proc.kill()
        cls.mock.shutdown()


if __name__ == "__main__":
    unittest.main()
