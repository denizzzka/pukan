#!/usr/bin/env python3
"""Packs the generated fixtures into an unencrypted Godot 4 PCK v2."""

import hashlib
import struct
from pathlib import Path

root = Path(__file__).resolve().parent
names = ["procedural.tscn", "procedural_mesh.res", "checker.png", "nested.tscn"]
entries = [(f"res://{name}", (root / name).read_bytes()) for name in names]

directory = bytearray()
data_offset = 0
for path, data in entries:
    encoded = path.encode()
    directory += struct.pack("<I", len(encoded))
    directory += encoded
    directory += struct.pack("<Q", data_offset)
    directory += struct.pack("<Q", len(data))
    directory += hashlib.md5(data).digest()
    directory += struct.pack("<I", 0)
    data_offset += len(data)

header_size = 4 + 4 + 4 * 3 + 4 + 8 + 16 * 4 + 4
file_base = header_size + len(directory)

header = b"GDPC"
header += struct.pack("<I", 2)
header += struct.pack("<III", 4, 7, 0)
header += struct.pack("<I", 0)
header += struct.pack("<Q", file_base)
header += b"\0" * (16 * 4)
header += struct.pack("<I", len(entries))
assert len(header) == header_size

(root / "fixtures.pck").write_bytes(header + directory + b"".join(data for _, data in entries))
