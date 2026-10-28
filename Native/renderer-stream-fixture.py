"""Serve generated H.264 frames over scrcpy's local video wire; no phone access."""
import pathlib
import socket
import struct
import sys
import time

frame = pathlib.Path(sys.argv[1]).read_bytes()
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(1)
listener.settimeout(30)
pathlib.Path(sys.argv[2]).write_text(str(listener.getsockname()[1]))
peer, _ = listener.accept()
with peer:
    peer.sendall(b'\x00' + b'Synthetic phone'.ljust(64, b'\x00') + b'h264')
    peer.sendall(struct.pack('>III', 0x80000000, 360, 800))
    black = pathlib.Path(sys.argv[3]).read_bytes() if len(sys.argv) > 3 else None
    frames = ([black] * 25 if black else []) + [frame] * 20
    for index, payload in enumerate(frames):
        peer.sendall(struct.pack('>QI', (1 << 61) | index * 100_000, len(payload)) + payload)
        time.sleep(0.1)
    time.sleep(0.5)
listener.close()
