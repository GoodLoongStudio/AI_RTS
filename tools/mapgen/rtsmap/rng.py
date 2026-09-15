"""闸门子 Seed：sha256(f"{master_seed}|{gate}|{algo_version}") 前 8 字节 little-endian → PCG64。

禁止内建 random、hash()、依赖 set/dict 迭代顺序；所有随机性必须来自本模块返回的
numpy Generator（同 Seed 同版本重跑完全一致）。
"""
import hashlib

import numpy as np


def gate_seed_int(master_seed: int, gate: str, algo_version: str) -> int:
    digest = hashlib.sha256(f"{master_seed}|{gate}|{algo_version}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "little")


def gate_rng(master_seed: int, gate: str, algo_version: str) -> np.random.Generator:
    seed_int = gate_seed_int(master_seed, gate, algo_version)
    return np.random.Generator(np.random.PCG64(seed_int))
