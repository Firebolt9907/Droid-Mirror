"""File transfer with the phone over the authenticated BLE background session
(the companion's clipboard-file protocol with `bulk: 0`).

Computer → phone: files are saved in the phone's Downloads folder (APKs too,
for installation on the phone). Phone → computer: a file copied on the phone is
saved in this computer's Downloads folder. One transfer at a time per
direction, under 5 MB, verified with SHA-256, flow-controlled by the phone's
acknowledgement window.
"""

from __future__ import annotations

import base64
import hashlib
import uuid
from pathlib import Path
from typing import Callable

from gi.repository import GLib

LIMIT = 5_000_000
CHUNK = 3072
WINDOW = 8


def downloads_dir() -> Path:
    path = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD)
    return Path(path) if path else Path.home() / "Downloads"


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode().replace("+", "-").replace("/", "_")


class FileTransfers:
    def __init__(self, send: Callable[[dict], bool], notify: Callable[[str, str, Path | None], None]):
        self.send = send
        self.notify = notify
        self.outgoing: dict | None = None
        self.incoming: dict | None = None
        self.queue: list[Path] = []

    # -- computer → phone ----------------------------------------------------------

    def send_file(self, path: Path) -> str | None:
        """Queues a file; returns an error message or None."""
        try:
            size = path.stat().st_size
        except OSError as error:
            return f"Could not read {path.name}: {error.strerror}"
        if size >= LIMIT:
            return f"{path.name} is larger than 5 MB."
        self.queue.append(path)
        if not self.outgoing:
            self._next()
        return None

    def _next(self) -> None:
        while self.queue and not self.outgoing:
            path = self.queue.pop(0)
            try:
                data = path.read_bytes()
            except OSError:
                continue
            identifier = str(uuid.uuid4())
            self.outgoing = {"id": identifier, "name": path.name, "data": data, "offset": 0, "window": 1}
            if not self.send({"type": "clipboardFileBegin", "id": identifier, "name": path.name[:200], "size": len(data),
                              "window": WINDOW, "destination": "downloads", "sha256": hashlib.sha256(data).hexdigest()}):
                self.outgoing = None
                self.notify("Could not send file", f"{path.name}: the phone is not connected.", None)
                self.queue.clear()

    def _acknowledged(self, event: dict) -> None:
        transfer = self.outgoing
        offset = event.get("offset", -1)
        if offset != transfer["offset"]:
            self._cancel_outgoing("The phone rejected the transfer.")
            return
        data = transfer["data"]
        if offset >= len(data) and offset > 0 or (offset == 0 and not data):
            self.notify("Sent to phone", f"{transfer['name']} is in the phone's Downloads folder.", None)
            self.outgoing = None
            self._next()
            return
        if offset == 0:
            transfer["window"] = max(1, min(int(event.get("window", 1)), WINDOW))
        for _ in range(transfer["window"]):
            chunk = data[transfer["offset"]: transfer["offset"] + CHUNK]
            if not chunk:
                break
            self.send({"type": "clipboardFileChunk", "id": transfer["id"], "offset": transfer["offset"], "data": _b64(chunk)})
            transfer["offset"] += len(chunk)

    def _cancel_outgoing(self, reason: str) -> None:
        if self.outgoing:
            self.send({"type": "clipboardFileCancel", "id": self.outgoing["id"], "offset": 0})
            self.notify("Could not send file", f"{self.outgoing['name']}: {reason}", None)
        self.outgoing = None
        self._next()

    # -- phone → computer ----------------------------------------------------------

    def _begin(self, event: dict) -> None:
        size = event.get("size", -1)
        name = Path(str(event.get("name", "file"))).name or "file"
        identifier = event.get("id")
        if not isinstance(size, int) or not 0 <= size < LIMIT:
            self.send({"type": "clipboardFileCancel", "id": identifier, "offset": 0})
            return
        window = max(1, min(int(event.get("window", 1)), WINDOW))
        self.incoming = {"id": identifier, "name": name, "size": size, "window": window, "sha256": event.get("sha256", ""),
                         "data": bytearray(), "since_ack": 0}
        if size == 0:
            self._complete()
        else:
            self.send({"type": "clipboardFileAck", "id": identifier, "offset": 0, "window": window})

    def _chunk(self, event: dict) -> None:
        transfer = self.incoming
        if event.get("offset") != len(transfer["data"]):
            self._cancel_incoming()
            return
        try:
            chunk = base64.b64decode(str(event.get("data", "")).replace("-", "+").replace("_", "/") + "==")
        except ValueError:
            self._cancel_incoming()
            return
        if not chunk or len(chunk) > CHUNK or len(transfer["data"]) + len(chunk) > transfer["size"]:
            self._cancel_incoming()
            return
        transfer["data"] += chunk
        transfer["since_ack"] += 1
        if len(transfer["data"]) == transfer["size"]:
            self._complete()
        elif transfer["since_ack"] == transfer["window"]:
            transfer["since_ack"] = 0
            self.send({"type": "clipboardFileAck", "id": transfer["id"], "offset": len(transfer["data"])})

    def _complete(self) -> None:
        transfer, self.incoming = self.incoming, None
        data = bytes(transfer["data"])
        if transfer["sha256"] and hashlib.sha256(data).hexdigest() != transfer["sha256"]:
            self.send({"type": "clipboardFileCancel", "id": transfer["id"], "offset": 0})
            return
        folder = downloads_dir()
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / transfer["name"]
        stem, suffix, n = target.stem, target.suffix, 1
        while target.exists():
            target = folder / f"{stem} ({n}){suffix}"
            n += 1
        target.write_bytes(data)
        self.send({"type": "clipboardFileAck", "id": transfer["id"], "offset": len(data)})
        self.notify("File from your phone", f"Saved {target.name} in Downloads.", target)

    def _cancel_incoming(self) -> None:
        if self.incoming:
            self.send({"type": "clipboardFileCancel", "id": self.incoming["id"], "offset": 0})
        self.incoming = None

    # -- dispatch ------------------------------------------------------------------------

    def receive(self, event: dict) -> None:
        kind, identifier = event.get("type"), event.get("id")
        if kind == "clipboardFileBegin":
            self._begin(event)
        elif kind == "clipboardFileChunk" and self.incoming and identifier == self.incoming["id"]:
            self._chunk(event)
        elif kind == "clipboardFileAck" and self.outgoing and identifier == self.outgoing["id"]:
            self._acknowledged(event)
        elif kind == "clipboardFileCancel":
            if self.incoming and identifier == self.incoming["id"]:
                self.incoming = None
            if self.outgoing and identifier == self.outgoing["id"]:
                name = self.outgoing["name"]
                self.outgoing = None
                self.notify("Could not send file", f"{name}: the phone cancelled the transfer (unlock it and keep DroidMirror's clipboard access enabled).", None)
                self._next()

    def reset(self) -> None:
        self.outgoing = self.incoming = None
        self.queue.clear()
