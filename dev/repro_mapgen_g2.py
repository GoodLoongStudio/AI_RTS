# -*- coding: utf-8 -*-
"""用 pipeline 自己的 generator_params 复现 G2 地貌检查失败。"""
import json
import sys
import traceback
from pathlib import Path

MAPGEN = Path("G:/AIRTS/AI_RTS/tools/mapgen")
sys.path.insert(0, str(MAPGEN))

from rtsmap.contract import G1_DEFAULTS  # noqa: E402
from rtsmap.gates import g1_starts, g2_layout  # noqa: E402
from rtsmap.workbench.settings import generator_params  # noqa: E402

job_path = MAPGEN / "workbench_output" / "d4f1fc39f4894c648203525997d09635" / "job.json"
job = json.loads(job_path.read_text(encoding="utf-8"))
cfg = job["config"]
params = generator_params(cfg)
print("river_width param:", params["river_width"], type(params["river_width"]).__name__)
print("plateau_count:", params["plateau_count"])

runs = MAPGEN / "runs_repro_g2"
runs.mkdir(parents=True, exist_ok=True)


def main():
    for seed in [36, 5, 4, 18]:
        print("=" * 60)
        print("layout seed", seed)
        try:
            g1_starts.run_one(seed, runs, dict(G1_DEFAULTS))
        except Exception:
            traceback.print_exc()
            continue
        try:
            res = g2_layout.run_one(seed, runs, dict(params), auto=True)
            spec = res["mapspec"]
            print("  all_pass=", spec.get("all_pass"))
            checks = spec.get("checks") or {}
            failed = [k for k, v in checks.items() if not v]
            print("  failed checks:", failed)
            print("  summary:", json.dumps(spec.get("summary") or {}, ensure_ascii=False)[:300])
        except Exception:
            traceback.print_exc()


if __name__ == "__main__":
    main()
