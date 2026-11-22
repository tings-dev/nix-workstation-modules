"""Bounded agent service registration over a local, systemd-owned Unix socket."""

import argparse
import json
import os
import re
import socket
import ssl
import struct
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

SOCKET = "/run/agent-services/control.sock"
MAX_REQUEST = 4096
MAX_SERVICES = 1024
LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", re.ASCII)


def validate(name, port=None):
    if not isinstance(name, str) or LABEL.fullmatch(name) is None:
        raise ValueError(
            "service name must be one lowercase DNS label (1–63 characters)"
        )
    if port is not None and (
        type(port) is not int or not 1 <= port <= 65535 or port == 443
    ):
        raise ValueError(
            "port must be an integer in 1..65535, excluding proxy port 443"
        )


def atomic_json(path, value):
    """Replace a service-owned file without exposing a partially written config."""
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o640)
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


class Registry:
    def __init__(self, config):
        self.config = config
        self.namespace = config["namespace"]
        self.state = Path(config["stateDirectory"]) / "registrations.json"
        # JSON is valid YAML; Traefik's directory provider only watches files
        # with YAML/TOML extensions. Keep the stdlib serializer and use .yaml.
        self.routes = Path(config["stateDirectory"]) / "dynamic/routes.yaml"
        self.routes.parent.mkdir(mode=0o750, exist_ok=True)
        self.registrations = (
            json.loads(self.state.read_text()) if self.state.exists() else {}
        )
        if (
            not isinstance(self.registrations, dict)
            or len(self.registrations) > MAX_SERVICES
        ):
            raise ValueError(
                "invalid persisted registrations; operator repair required"
            )
        for name, port in self.registrations.items():
            if type(port) is not int:
                raise ValueError("invalid persisted port; operator repair required")
            validate(name, port)
        # The registry is authoritative after a crash between file replacements,
        # and routes are regenerated when the configured namespace changes.
        atomic_json(self.routes, self.render(self.registrations))

    def render(self, registrations):
        tls = {
            "certResolver": "letsencrypt",
            "domains": [{"main": f"*.{self.namespace}"}],
        }
        # Keep certificate provisioning independent of whether any application
        # is registered. The namespace apex itself is outside the wildcard cert.
        routers = {
            "certificate-bootstrap": {
                "rule": f"Host(`{self.namespace}`)",
                "entryPoints": ["https"],
                "service": "noop@internal",
                "tls": tls,
            }
        }
        services = {}
        for name, port in sorted(registrations.items()):
            key = f"service-{name}"
            routers[key] = {
                "rule": f"Host(`{name}.{self.namespace}`)",
                "entryPoints": ["https"],
                "service": key,
                "tls": tls,
            }
            services[key] = {
                "loadBalancer": {"servers": [{"url": f"http://127.0.0.1:{port}"}]}
            }
        http = {"routers": routers}
        if services:
            http["services"] = services
        return {
            "http": http,
            "tls": {
                "options": {
                    "default": {"minVersion": "VersionTLS12", "sniStrict": True}
                }
            },
        }

    def save(self, registrations):
        # Persist intent first; a restart can always regenerate matching routes.
        previous = self.registrations
        atomic_json(self.state, registrations)
        try:
            atomic_json(self.routes, self.render(registrations))
        except OSError:
            atomic_json(self.state, previous)
            raise
        self.registrations = registrations

    def listing(self):
        return [
            {"name": name, "port": port, "url": f"https://{name}.{self.namespace}"}
            for name, port in sorted(self.registrations.items())
        ]

    def status(self):
        result = {
            "namespace": self.namespace,
            "registrations": len(self.registrations),
            "httpsReady": False,
        }
        try:
            context = ssl.create_default_context(cafile=self.config.get("caBundle"))
            with (
                socket.create_connection(("127.0.0.1", 443), timeout=3) as connection,
                context.wrap_socket(
                    connection, server_hostname=f"agent-service-status.{self.namespace}"
                ) as tls,
            ):
                certificate = tls.getpeercert()
            if ("DNS", f"*.{self.namespace}") not in certificate.get(
                "subjectAltName", ()
            ):
                raise ValueError(
                    "proxy is not serving the environment's wildcard certificate"
                )
            result.update(
                httpsReady=True,
                certificateExpires=datetime.fromtimestamp(
                    ssl.cert_time_to_seconds(certificate["notAfter"]), UTC
                ).isoformat(),
            )
        except (OSError, ValueError) as error:
            result["error"] = (
                f"HTTPS unavailable: {error}. Operator: check DNS and journalctl -u traefik."
            )
        return result

    def request(self, request):
        if not isinstance(request, dict):
            raise TypeError("request must be an object")
        operation = request.get("operation")
        fields = {
            "register": {"operation", "name", "port"},
            "unregister": {"operation", "name"},
            "list": {"operation"},
            "status": {"operation"},
        }
        if (
            not isinstance(operation, str)
            or operation not in fields
            or set(request) != fields[operation]
        ):
            raise ValueError("unknown operation or unexpected request fields")
        if operation == "list":
            return self.listing()
        if operation == "status":
            return self.status()
        name = request["name"]
        if operation == "register":
            # None is not a valid port, even though validate(name) is also used
            # by unregister, which has no port field.
            if type(request["port"]) is not int:
                raise ValueError("port must be an integer")
            validate(name, request["port"])
            updated = self.registrations | {name: request["port"]}
            if len(updated) > MAX_SERVICES:
                raise ValueError(f"at most {MAX_SERVICES} services may be registered")
        else:
            validate(name)
            updated = {
                key: port for key, port in self.registrations.items() if key != name
            }
        self.save(updated)
        return {"url": f"https://{name}.{self.namespace}", "operation": operation}


def receive(stream, limit):
    data = stream.readline(limit + 1)
    if len(data) > limit or not data.endswith(b"\n"):
        raise ValueError("request is too large or missing its newline")
    return json.loads(data)


def serve(config):
    if (
        os.environ.get("LISTEN_PID") != str(os.getpid())
        or os.environ.get("LISTEN_FDS") != "1"
    ):
        raise ValueError("registration service requires its systemd socket")
    registry = Registry(config)
    with socket.socket(fileno=3) as listener:
        if address := os.environ.get("NOTIFY_SOCKET"):
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notification:
                notification.connect(
                    "\0" + address[1:] if address.startswith("@") else address
                )
                notification.sendall(b"READY=1")
        while True:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(5)
                try:
                    _, uid, _ = struct.unpack(
                        "3i",
                        connection.getsockopt(
                            socket.SOL_SOCKET, socket.SO_PEERCRED, 12
                        ),
                    )
                    if uid not in (0, config["agentUid"]):
                        raise ValueError("only the agent account may register services")
                    with connection.makefile("rb") as stream:
                        response = {
                            "ok": True,
                            "result": registry.request(receive(stream, MAX_REQUEST)),
                        }
                except (
                    TypeError,
                    ValueError,
                    UnicodeError,
                    OSError,
                    RecursionError,
                ) as error:
                    # Filesystem paths may be useful to the operator; neither
                    # registry files nor TLS probes contain credential values.
                    response = {"ok": False, "error": str(error)}
                try:
                    connection.sendall(json.dumps(response).encode() + b"\n")
                except OSError:
                    pass


def client(request, path=SOCKET):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(15)
        connection.connect(path)
        connection.sendall(json.dumps(request).encode() + b"\n")
        with connection.makefile("rb") as stream:
            response = receive(stream, 1024 * 1024)
    if not response["ok"]:
        raise ValueError(response["error"])
    return response["result"]


def main():
    # This process mode is only used by the system unit, not the agent CLI.
    if sys.argv[1:2] == ["serve"]:
        daemon = argparse.ArgumentParser()
        daemon.add_argument("serve")
        daemon.add_argument("--config", required=True)
        args = daemon.parse_args()
        try:
            serve(json.loads(Path(args.config).read_text()))
            return 0
        except (ValueError, OSError) as error:
            print(f"agent-service: {error}", file=sys.stderr)
            return 1
    parser = argparse.ArgumentParser(
        prog="agent-service",
        description="Register local HTTP services in this agent environment",
    )
    parser.add_argument(
        "--json", action="store_true", help="print machine-readable results"
    )
    commands = parser.add_subparsers(dest="operation", required=True)
    register = commands.add_parser(
        "register", help="register or replace a service's local HTTP port"
    )
    register.add_argument("name")
    register.add_argument("--port", required=True, type=int)
    commands.add_parser(
        "unregister", help="remove a service registration"
    ).add_argument("name")
    commands.add_parser("list", help="list registered names, ports and HTTPS URLs")
    commands.add_parser(
        "status", help="check proxy and trusted wildcard certificate readiness"
    )
    args = parser.parse_args()
    try:
        request = {"operation": args.operation}
        for key in ("name", "port"):
            if hasattr(args, key):
                request[key] = getattr(args, key)
        result = client(request)
        if args.json:
            print(json.dumps(result, sort_keys=True))
        elif args.operation == "register":
            print(result["url"])
        elif args.operation == "unregister":
            print(f"Removed {result['url']}")
        elif args.operation == "list":
            for service in result:
                print(f"{service['name']}\t{service['port']}\t{service['url']}")
        else:
            print(
                f"Namespace: {result['namespace']}\nRegistrations: {result['registrations']}"
            )
            print(
                f"HTTPS ready; certificate expires {result['certificateExpires']}"
                if result["httpsReady"]
                else result["error"]
            )
        return 1 if args.operation == "status" and not result["httpsReady"] else 0
    except (TypeError, ValueError, OSError) as error:
        print(f"agent-service: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
