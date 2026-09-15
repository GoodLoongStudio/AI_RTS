"""汇总输出：manifest / summary.json / summary.csv / README。"""
import csv
from pathlib import Path

from .grid import write_json


def summary_dir(runs_root, gate: str) -> Path:
    d = Path(runs_root) / f"{gate}_summary"
    d.mkdir(parents=True, exist_ok=True)
    return d


def write_summary_json(path, obj) -> None:
    write_json(path, obj)


def write_summary_csv(path, rows) -> None:
    if not rows:
        Path(path).write_text("", encoding="utf-8")
        return
    keys = list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        for r in rows:
            writer.writerow(r)


def write_text(path, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8", newline="\n")
