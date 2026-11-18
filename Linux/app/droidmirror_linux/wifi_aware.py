"""Wi-Fi Aware (NAN) video path for Linux.

Requirements: a Wi-Fi adapter whose driver offers the NAN interface mode
(`iw list` → "Supported interface modes" lists NAN), and wpa_supplicant 2.12+
with NAN support whose control socket this user may access (for example
`ctrl_interface=DIR=/run/wpa_supplicant GROUP=network` and membership in that
group, or DROIDMIRROR_WPA_CTRL pointing at an accessible socket).

Flow, during an active mirror session (the phone publishes only then):
  1. NAN_SUBSCRIBE to "droidmirror"; match the publish whose service-specific
     info equals HMAC(pairing key, "DroidMirror Wi-Fi Aware service v1")[:16].
  2. Send a follow-up proving the same key ("… request v1"); the phone replies
     with its TCP port and accepts a data path secured by a passphrase derived
     from the key.
  3. NAN_NDP_REQUEST; on NAN-NDP-CONNECTED, connect to the phone's IPv6
     link-local address on the NAN data interface and relay it through a
     loopback port that the helper probes with `UPGRADE <port>`. The helper's
     usual pairing-proof handshake (DMWIFI05/06) still gates all video.

The NDP request parameters follow hostap's NAN control interface; they could
not be exercised on the development laptop (Intel AX201 has no NAN mode).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
import socket
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Callable

from gi.repository import GLib

from . import config

SERVICE = "droidmirror"


def _derive(key: bytes, label: str, length: int) -> bytes:
    return hmac.new(key, label.encode(), hashlib.sha256).digest()[:length]


def service_token(key: bytes) -> bytes:
    return _derive(key, "DroidMirror Wi-Fi Aware service v1", 16)


def request_token(key: bytes) -> bytes:
    return _derive(key, "DroidMirror Wi-Fi Aware request v1", 16)


def passphrase(key: bytes) -> str:
    return base64.b64encode(_derive(key, "DroidMirror Wi-Fi Aware passphrase v1", 24)).decode().rstrip("=")


def support() -> tuple[bool, str]:
    """(supported, human-readable reason)."""
    try:
        listing = subprocess.run(["iw", "list"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return False, "Install iw to detect Wi-Fi Aware support."
    modes = re.search(r"Supported interface modes:\n((?:\s+\* .*\n)+)", listing)
    if not modes or not re.search(r"\*\s+NAN\b", modes.group(1)):
        return False, "This Wi-Fi adapter's driver doesn't support Wi-Fi Aware (NAN)."
    if not control_socket():
        return False, "Wi-Fi Aware needs access to wpa_supplicant's control socket (see the Linux README)."
    return True, "Wi-Fi Aware available"


def control_socket() -> str | None:
    candidates = [os.environ.get("DROIDMIRROR_WPA_CTRL")]
    base = Path("/run/wpa_supplicant")
    try:
        candidates += [str(p) for p in base.iterdir() if not p.name.startswith("p2p")]
    except OSError:
        pass
    for path in candidates:
        if path and os.path.exists(path) and os.access(path, os.W_OK):
            return path
    return None


def _link_local(mac: str) -> str:
    octets = [int(x, 16) for x in mac.split(":")]
    octets[0] ^= 0x02
    eui = octets[:3] + [0xFF, 0xFE] + octets[3:]
    groups = [f"{eui[i] << 8 | eui[i + 1]:x}" for i in range(0, 8, 2)]
    return "fe80::" + ":".join(groups)


class WifiAwareLink:
    """One phone's Wi-Fi Aware path for one mirror session."""

    def __init__(self, key: bytes, on_port: Callable[[int], None], on_status: Callable[[str], None]):
        self.key = key
        self.on_port = on_port
        self.on_status = on_status
        self.sock: socket.socket | None = None
        self.local_path = ""
        self.watch = None
        self.subscribe_id = None
        self.peer = None
        self.publish_id = None
        self.phone_port = 0
        self.relay: socket.socket | None = None
        self.closed = False

    def start(self) -> bool:
        path = control_socket()
        if not path:
            return False
        self.local_path = tempfile.mktemp(prefix="droidmirror-wpa-", dir=str(config.cache_dir()))
        config.cache_dir().mkdir(parents=True, exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(self.local_path)
        self.sock.connect(path)
        self.sock.setblocking(False)
        self.watch = GLib.io_add_watch(self.sock.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_IN, self._readable)
        self._send("ATTACH")
        self._send("NAN_START")
        self._send(f"NAN_SUBSCRIBE service_name={SERVICE} active=1 ssi={service_token(self.key).hex()}")
        self.on_status("Looking for the phone over Wi-Fi Aware")
        return True

    def _send(self, command: str) -> None:
        try:
            self.sock.send(command.encode())
        except OSError as error:
            self.on_status(f"Wi-Fi Aware control failed: {error}")

    def _readable(self, _fd, _condition) -> bool:
        try:
            data = self.sock.recv(4096).decode(errors="replace")
        except BlockingIOError:
            return True
        except OSError:
            return False
        line = re.sub(r"^<\d>", "", data.strip())
        fields = dict(re.findall(r"(\w+)=(\S+)", line))
        if line.startswith("NAN_SUBSCRIBE") or (line.isdigit() and self.subscribe_id is None):
            self.subscribe_id = line.split()[-1]
        elif line.startswith("NAN-DISCOVERY-RESULT") and fields.get("ssi", "").lower() == service_token(self.key).hex():
            self.peer, self.publish_id = fields.get("address"), fields.get("publish_id")
            self.subscribe_id = fields.get("subscribe_id", self.subscribe_id)
            self._send(f"NAN_TRANSMIT handle={self.subscribe_id} req_instance_id={self.publish_id} "
                       f"address={self.peer} ssi={request_token(self.key).hex()}")
        elif line.startswith("NAN-RECEIVE") and fields.get("address") == self.peer:
            ssi = bytes.fromhex(fields.get("ssi", ""))
            if len(ssi) == 2:
                self.phone_port = ssi[0] << 8 | ssi[1]
                self._send(f"NAN_NDP_REQUEST handle={self.subscribe_id} peer_nmi={self.peer} "
                           f"peer_id={self.publish_id} password={passphrase(self.key)}")
                self.on_status("Setting up the Wi-Fi Aware data path")
        elif line.startswith("NAN-NDP-CONNECTED") and self.phone_port:
            interface = fields.get("interface_id") or ""
            self._start_relay(_link_local(fields["peer_ndi"]), interface)
        return True

    def _start_relay(self, address: str, interface: str) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.relay = listener
        port = listener.getsockname()[1]
        target = (f"{address}%{interface}" if interface else address, self.phone_port)

        def serve():
            while not self.closed:
                try:
                    local, _ = listener.accept()
                except OSError:
                    return
                try:
                    remote = socket.create_connection(target, timeout=5)
                except OSError:
                    local.close()
                    continue
                for a, b in ((local, remote), (remote, local)):
                    threading.Thread(target=self._pump, args=(a, b), daemon=True).start()

        threading.Thread(target=serve, daemon=True).start()
        self.on_status("Wi-Fi Aware data path ready")
        self.on_port(port)

    @staticmethod
    def _pump(source: socket.socket, destination: socket.socket) -> None:
        try:
            while data := source.recv(65536):
                destination.sendall(data)
        except OSError:
            pass
        finally:
            for s in (source, destination):
                try:
                    s.close()
                except OSError:
                    pass

    def close(self) -> None:
        self.closed = True
        if self.sock:
            if self.subscribe_id:
                self._send(f"NAN_CANCEL_SUBSCRIBE subscribe_id={self.subscribe_id}")
            self._send("DETACH")
            if self.watch:
                GLib.source_remove(self.watch)
            self.sock.close()
            self.sock = None
            try:
                os.unlink(self.local_path)
            except OSError:
                pass
        if self.relay:
            self.relay.close()
