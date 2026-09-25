# -*- coding: utf-8 -*-
"""复现 mapgen G3 崩溃（list index out of range）并打印完整堆栈。"""
import json
import sys
import traceback
from pathlib import Path

MAPGEN = Path("G:/AIRTS/AI_RTS/tools/mapgen")
sys.path.insert(0, str(MAPGEN))

from rtsmap.gates import g3_content  # noqa: E402

job_path = MAPGEN / "workbench_output" / "d4f1fc39f4894c648203525997d09635" / "job.json"
job = json.loads(job_path.read_text(encoding="utf-8"))
cfg = job["config"]
layout_seed = int(cfg["layout_seed"])
terrain_seed = int(cfg["terrain_seed"])
print("layout_seed", layout_seed, "terrain_seed", terrain_seed)

# G3 的 seed 用的是 layout_seed（pipeline 里 g3_content.run_one(seed, ...) 的 seed）
runs = MAPGEN / "workbench_output" / "d4f1fc39f4894c648203525997d09635" / "runs"

try:
    res = g3_content.run_one(layout_seed, runs, dict(g3_content.G3_DEFAULTS), auto=True)
    print("OK:", json.dumps(res, ensure_ascii=False)[:400] if isinstance(res, dict) else res)
except Exception:
    traceback.print_exc()
