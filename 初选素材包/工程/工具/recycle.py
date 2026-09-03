# -*- coding: utf-8 -*-
"""把目录送进回收站（可恢复），用 Win32 SHFileOperationW。

不依赖 Add-Type / COM / send2trash —— 那三样在当前环境都被拦或有中文路径 bug。
路径必须以双 \\0 结尾（SHFileOperationW 要求）。
"""
import ctypes
import os
import sys
from ctypes import wintypes


class SHFILEOPSTRUCTW(ctypes.Structure):
    _fields_ = [
        ("hwnd", wintypes.HWND),
        ("wFunc", wintypes.UINT),
        ("pFrom", wintypes.LPCWSTR),
        ("pTo", wintypes.LPCWSTR),
        ("fFlags", ctypes.c_uint16),
        ("fAnyOperationsAborted", wintypes.BOOL),
        ("hNameMappings", ctypes.c_void_p),
        ("lpszProgressTitle", wintypes.LPCWSTR),
    ]


FO_DELETE = 3
FOF_SILENT = 0x0004
FOF_NOCONFIRMATION = 0x0010
FOF_ALLOWUNDO = 0x0040
FOF_NOERRORUI = 0x0400


def to_recycle_bin(path: str) -> None:
    path = os.path.abspath(path)
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    op = SHFILEOPSTRUCTW()
    op.hwnd = None
    op.wFunc = FO_DELETE
    op.pFrom = path + "\0\0"
    op.pTo = None
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI
    res = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))
    if res != 0:
        raise OSError(f"SHFileOperationW failed code={res}")
    if op.fAnyOperationsAborted:
        raise OSError("operation aborted")


def dir_size_mb(path: str) -> float:
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total / 1048576


if __name__ == "__main__":
    for target in sys.argv[1:]:
        if not os.path.exists(target):
            print("missing  ", target)
            continue
        mb = dir_size_mb(target)
        n = sum(len(f) for _, _, f in os.walk(target))
        to_recycle_bin(target)
        print("recycled %-10s %7.0f MB %6d files  exists=%s"
              % (os.path.basename(target), mb, n, os.path.exists(target)))
