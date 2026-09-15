"""闸门机制：manifest 读写、approved 检查、--approve 实现。"""
import datetime
from pathlib import Path

from .contract import GATES
from .grid import read_json, write_json


def run_dir(runs_root, seed: int, gate: str) -> Path:
    return Path(runs_root) / str(seed) / gate


def manifest_path(runs_root, seed: int, gate: str) -> Path:
    return run_dir(runs_root, seed, gate) / "manifest.json"


def load_manifest(runs_root, seed: int, gate: str) -> dict:
    return read_json(manifest_path(runs_root, seed, gate))


def write_manifest(runs_root, seed: int, gate: str, manifest: dict) -> None:
    write_json(manifest_path(runs_root, seed, gate), manifest)


def new_manifest(master_seed: int, gate: str, gate_seed: int, algo_version: str,
                 params: dict, input_hash, output_hash: dict) -> dict:
    return {
        "master_seed": master_seed,
        "gate": gate,
        "gate_seed": gate_seed,
        "algo_version": algo_version,
        "params": params,
        "input_hash": input_hash,
        "output_hash": output_hash,
        "created_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "approved": False,
        "approved_note": None,
        "approved_at": None,
    }


def is_approved(runs_root, seed: int, gate: str) -> bool:
    p = manifest_path(runs_root, seed, gate)
    if not p.exists():
        return False
    return bool(load_manifest(runs_root, seed, gate).get("approved", False))


def upstream_gate(gate: str):
    idx = GATES.index(gate)
    return GATES[idx - 1] if idx > 0 else None


def ensure_upstream_approved(runs_root, seed: int, gate: str) -> None:
    """下游闸门运行前必须检查上游 approved == true，否则拒绝运行。"""
    up = upstream_gate(gate)
    if up is None:
        return
    if not is_approved(runs_root, seed, up):
        raise RuntimeError(
            f"闸门 {gate} 拒绝运行：Seed {seed} 的上游 {up} 未 approve"
            f"（运行 python run.py --approve {up} --seeds {seed}）"
        )


def approved_seeds(runs_root, gate: str) -> list:
    """扫描 runs_root 下 <seed>/<gate>/manifest.json 中 approved==true 的 Seed，升序返回。"""
    root = Path(runs_root)
    if not root.exists():
        return []
    out = []
    for child in sorted(root.iterdir(), key=lambda p: p.name):
        if not child.is_dir() or not child.name.isdigit():
            continue
        if is_approved(runs_root, int(child.name), gate):
            out.append(int(child.name))
    return out


def approve(runs_root, gate: str, seeds, note: str) -> list:
    done = []
    for seed in seeds:
        p = manifest_path(runs_root, seed, gate)
        if not p.exists():
            raise FileNotFoundError(f"未找到 {p}，无法 approve Seed {seed}")
        mf = load_manifest(runs_root, seed, gate)
        mf["approved"] = True
        mf["approved_note"] = note
        mf["approved_at"] = datetime.datetime.now().isoformat(timespec="seconds")
        write_manifest(runs_root, seed, gate, mf)
        done.append(seed)
    return done
