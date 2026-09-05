# -*- coding: utf-8 -*-
# 最小 Godot 4 GDPC 解包器: 提取 quaternius animviewer pck 内的资源 (期望含全动画 GLB)
import struct, sys, os

PCK = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\mocap\ual_index.pck"
OUT = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\mocap\ual_extract"
os.makedirs(OUT, exist_ok=True)

data = open(PCK, "rb").read()
assert data[:4] == b"GDPC", "not a pck"
off = 4
ver = struct.unpack_from("<I", data, off)[0]; off += 4
g_major, g_minor, g_patch = struct.unpack_from("<III", data, off); off += 12
print("pack ver", ver, "godot", g_major, g_minor, g_patch)
pack_flags = struct.unpack_from("<I", data, off)[0]; off += 4
file_base = 0
if ver >= 2:
    file_base = struct.unpack_from("<Q", data, off)[0]; off += 8
off += 16 * 4  # reserved
n_files = struct.unpack_from("<I", data, off)[0]; off += 4
print("files", n_files, "pack_flags", pack_flags, "file_base", file_base)
if pack_flags & 1:
    print("PACK_ENCRYPTED — 无法直接解包")
    sys.exit(1)

for i in range(n_files):
    plen = struct.unpack_from("<I", data, off)[0]; off += 4
    path = data[off:off + plen].rstrip(b"\0").decode("utf-8"); off += plen
    foff = struct.unpack_from("<Q", data, off)[0]; off += 8
    fsize = struct.unpack_from("<Q", data, off)[0]; off += 8
    off += 16  # md5
    flags = 0
    if ver >= 2:
        flags = struct.unpack_from("<I", data, off)[0]; off += 4
    start = file_base + foff if ver >= 2 else foff
    blob = data[start:start + fsize]
    outp = os.path.join(OUT, path.replace("res://", "").replace("/", "_"))
    with open(outp, "wb") as f:
        f.write(blob)
    print("EXTRACTED", path, fsize // 1024, "KB", "flags", flags)
print("PCK_DONE")
