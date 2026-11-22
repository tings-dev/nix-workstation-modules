"""Exercise the registration boundary with real files and a real Unix socket."""

import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "nixos/agent-services.py"
spec = importlib.util.spec_from_file_location("services", SOURCE)
services = importlib.util.module_from_spec(spec)
spec.loader.exec_module(services)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.config = {
            "namespace": "agent-test.envs.example.test",
            "agentUid": os.getuid(),
            "stateDirectory": str(self.directory),
        }
        self.registry = services.Registry(self.config)

    def register(self, name="web", port=3000):
        return self.registry.request(
            {"operation": "register", "name": name, "port": port}
        )

    def test_replacement_removal_and_restart(self):
        self.assertEqual(
            self.register()["url"], "https://web.agent-test.envs.example.test"
        )
        self.register(port=4000)
        self.register("api", 8080)
        restarted = services.Registry(self.config)
        self.assertEqual(restarted.registrations, {"web": 4000, "api": 8080})
        self.registry.request({"operation": "unregister", "name": "web"})
        self.registry.request({"operation": "unregister", "name": "web"})
        self.assertEqual(services.Registry(self.config).registrations, {"api": 8080})
        self.assertEqual(self.registry.routes.stat().st_mode & 0o777, 0o640)
        listing = self.registry.request({"operation": "list"})
        self.assertEqual(
            [(row["name"], row["port"]) for row in listing], [("api", 8080)]
        )

    def test_untrusted_input_cannot_change_existing_routes(self):
        self.register()
        original_state = self.registry.state.read_bytes()
        original_routes = self.registry.routes.read_bytes()
        invalid = (
            [
                {"operation": "register", "name": name, "port": 3000}
                for name in (
                    "",
                    "Web",
                    "a.b",
                    "../web",
                    "-web",
                    "web-",
                    "a" * 64,
                    "a`)",
                    "аpi",
                    None,
                    [],
                )
            ]
            + [
                {"operation": "register", "name": "web", "port": port}
                for port in (
                    None,
                    True,
                    "3000",
                    "3000/path",
                    "http://host:3000",
                    0,
                    443,
                    -1,
                    65536,
                )
            ]
            + [
                {
                    "operation": "register",
                    "name": "web",
                    "port": 3000,
                    "host": "192.168.1.1",
                },
                {"operation": "register", "name": "web", "port": 3000, "tls": False},
                {"operation": "unregister", "name": "../web"},
                {"operation": "stop"},
                {"operation": []},
                [],
            ]
        )
        for request in invalid:
            with (
                self.subTest(request=request),
                self.assertRaises((ValueError, TypeError)),
            ):
                self.registry.request(request)
            self.assertEqual(self.registry.state.read_bytes(), original_state)
            self.assertEqual(self.registry.routes.read_bytes(), original_routes)

    def test_routes_only_address_loopback_and_current_namespace(self):
        self.register("a-b", 65535)
        self.register("z", 1)
        self.config["namespace"] = "renamed.envs.example.test"
        restarted = services.Registry(self.config)
        routes = json.loads(restarted.routes.read_text())
        self.assertEqual(
            routes["http"]["services"]["service-a-b"]["loadBalancer"]["servers"],
            [{"url": "http://127.0.0.1:65535"}],
        )
        self.assertEqual(
            routes["http"]["routers"]["service-z"]["rule"],
            "Host(`z.renamed.envs.example.test`)",
        )
        self.assertTrue(routes["tls"]["options"]["default"]["sniStrict"])
        self.assertNotIn("certificates", routes["tls"])

    def test_corrupt_state_fails_instead_of_publishing_arbitrary_config(self):
        for state in ({"web": None}, {"../web": 3000}, {"web": "3000"}, []):
            self.registry.state.write_text(json.dumps(state))
            with self.assertRaises(ValueError):
                services.Registry(self.config)

    def test_actual_socket_protocol_and_malformed_request_recovery(self):
        path = str(self.directory / "control.sock")
        config = self.directory / "config.json"
        config.write_text(json.dumps(self.config))
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen()
            launcher = """
import os, runpy, sys
source, config, fd = sys.argv[1:]
os.dup2(int(fd), 3)
os.environ.update(LISTEN_PID=str(os.getpid()), LISTEN_FDS='1')
sys.argv = [source, 'serve', '--config', config]
runpy.run_path(source, run_name='__main__')
"""
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    launcher,
                    str(SOURCE),
                    str(config),
                    str(listener.fileno()),
                ],
                pass_fds=(listener.fileno(),),
            )
            try:
                result = services.client(
                    {"operation": "register", "name": "web", "port": 3000}, path
                )
                self.assertTrue(result["url"].startswith("https://web."))
                for payload in (
                    b"garbage\n",
                    b"{" + b"x" * 4096 + b"\n",
                    b"[" * 1500 + b"\n",
                ):
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.settimeout(10)
                        connection.connect(path)
                        connection.sendall(payload)
                        with connection.makefile("rb") as stream:
                            self.assertFalse(json.loads(stream.readline())["ok"])
                self.assertEqual(
                    services.client({"operation": "list"}, path)[0]["port"], 3000
                )
            finally:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
