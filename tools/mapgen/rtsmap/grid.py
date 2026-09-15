"""MapGrid：通道定义、npz 读写、哈希与规范化 JSON。

- npz 保存键顺序 = contract.CHANNEL_DTYPES 定义顺序（固定），字节级可复现。
- JSON 写入统一 sort_keys=True, ensure_ascii=False, indent=1，浮点先 round(x, 4)。
"""
import hashlib
import json
import math
from pathlib import Path

import numpy as np

from .contract import CHANNEL_DTYPES, GRID_H, GRID_W

_DTYPE_MAP = dict(CHANNEL_DTYPES)


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canon(obj):
    """递归规范化：numpy 标量 → python，浮点 round(4)。"""
    if isinstance(obj, dict):
        return {str(k): _canon(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_canon(v) for v in obj]
    if isinstance(obj, (bool, np.bool_)):
        return bool(obj)
    if isinstance(obj, (int, np.integer)):
        return int(obj)
    if isinstance(obj, (float, np.floating)):
        v = float(obj)
        if math.isnan(v) or math.isinf(v):
            return v
        return round(v, 4)
    if isinstance(obj, np.ndarray):
        return _canon(obj.tolist())
    return obj


def canon_json_bytes(obj) -> bytes:
    text = json.dumps(_canon(obj), indent=1, sort_keys=True, ensure_ascii=False)
    return text.encode("utf-8")


def write_json(path, obj) -> str:
    """规范化写入，返回内容的 sha256（供 manifest 记账）。"""
    data = canon_json_bytes(obj)
    Path(path).write_bytes(data)
    return sha256_bytes(data)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


class MapGrid:
    """96×96 格网的通道容器。上游通道对下游只读。"""

    def __init__(self, w: int = GRID_W, h: int = GRID_H):
        self.w = w
        self.h = h
        self.channels: dict[str, np.ndarray] = {}

    def set(self, name: str, arr) -> None:
        a = np.ascontiguousarray(arr)
        if a.dtype != _DTYPE_MAP[name]:
            a = a.astype(_DTYPE_MAP[name])
        if a.shape != (self.h, self.w):
            raise ValueError(f"channel {name}: shape {a.shape} != {(self.h, self.w)}")
        self.channels[name] = a

    def get(self, name: str) -> np.ndarray:
        return self.channels[name]

    def has(self, name: str) -> bool:
        return name in self.channels

    @classmethod
    def from_parent(cls, parent: "MapGrid", extra: dict | None = None) -> "MapGrid":
        """下游格网 = 上游全部通道原样复制 + 本闸门新增通道。"""
        g = cls(parent.w, parent.h)
        for k, v in parent.channels.items():
            g.channels[k] = v.copy()
        for k, v in (extra or {}).items():
            g.set(k, v)
        return g

    @classmethod
    def load(cls, path) -> "MapGrid":
        data = np.load(path)
        g = cls()
        for k in data.files:
            g.channels[k] = np.ascontiguousarray(data[k])
        return g

    def save(self, path) -> str:
        order = [name for name, _ in CHANNEL_DTYPES if name in self.channels]
        extra = [k for k in self.channels if k not in order]
        if extra:  # 未知通道追加在尾部（保持确定顺序）
            order += sorted(extra)
        with open(path, "wb") as f:
            np.savez(f, **{name: self.channels[name] for name in order})
        return sha256_file(path)
