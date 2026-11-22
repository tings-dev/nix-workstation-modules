"""Apply the workstation's Tailscale policy before Syncthing starts."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def prepare(syncthing):
    os.umask(0o077)
    home = Path.home()
    state = Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state") / "syncthing"
    legacy = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "syncthing"
    # Match Syncthing and Home Manager's preference for existing state.
    directory = state
    if not (state / "config.xml").exists() and (legacy / "config.xml").exists():
        directory = legacy
    config = directory / "config.xml"
    if not config.exists():
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        subprocess.run(
            [syncthing, "generate", "--home", str(directory), "--no-port-probing"],
            check=True,
        )

    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    tree = ET.parse(config, parser=parser)
    root = tree.getroot()
    if root.tag != "configuration":
        raise ValueError("Expected a Syncthing configuration element")
    options = root.find("options")
    if options is None:
        options = ET.SubElement(root, "options")

    # Explicit Tailscale peer addresses are entered in the GUI. The NixOS
    # companion restricts this TCP listener's incoming traffic to Tailscale.
    policy = {
        "listenAddress": "tcp://0.0.0.0:22000",
        "globalAnnounceEnabled": "false",
        "localAnnounceEnabled": "false",
        "natEnabled": "false",
        "relaysEnabled": "false",
        "stunKeepaliveStartS": "0",
    }
    for name, value in policy.items():
        for element in options.findall(name):
            options.remove(element)
        ET.SubElement(options, name).text = value

    # Replace atomically with a private file; never expose the GUI API key.
    descriptor, temporary = tempfile.mkstemp(prefix=".config-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as output:
            tree.write(output, encoding="utf-8", xml_declaration=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    prepare(sys.argv[1])
