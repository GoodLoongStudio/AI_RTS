"""Replay the workbench screenshot failure: 分流一湖 starting on layout 55."""
import json
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from rtsmap.gates.g2_layout import NoTerrainCandidate
from rtsmap.workbench.catalog import layout_catalog
from rtsmap.workbench.compat import bind_job_layout, next_layout_seed, record_layout_try
from rtsmap.workbench.settings import generator_params, validate_config
from rtsmap.gates import g2_layout as g2

PROJECT = ROOT


def main():
    layouts = layout_catalog(PROJECT)
    pool = [55, 16] + [item['seed'] for item in layouts if item['seed'] not in (55, 16)]
    job = dict(
        layout_locked=False, layout_pool=pool, layout_tried=[],
        config=validate_config(dict(
            layout_seed=55, terrain_seed=515487110,
            controls=dict(river_enabled=1, river_layout=3, lake_count=1, layout_attempts=4),
        ), [item['seed'] for item in layouts]),
        title='', spacing='standard',
    )
    tmp = Path(tempfile.mkdtemp(prefix='rotate55_'))
    tried = []
    try:
        while True:
            seed = job['config']['layout_seed']
            dest = tmp / str(seed) / 'G1'
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(PROJECT / 'runs' / str(seed) / 'G1', dest)
            print(f'try layout {seed}', flush=True)
            try:
                result = g2.run_one(seed, tmp, generator_params(job['config']), auto=True)
            except NoTerrainCandidate as error:
                print(f'  no_candidate {error.attempts}', flush=True)
                record_layout_try(job, seed, 'no_candidate', error.attempts)
                tried.append(seed)
                nxt = next_layout_seed(job)
                if nxt is None:
                    raise
                bind_job_layout(job, nxt, layouts)
                continue
            spec = result['mapspec']
            print(f'  all_pass={spec["all_pass"]} rivers={len(spec.get("rivers", []))} lakes={len(spec.get("lakes", []))} failed={[k for k,v in spec["checks"].items() if not v]}', flush=True)
            if spec['all_pass']:
                print(json.dumps(dict(ok=True, layout=seed, tried=tried + [seed],
                                      lakes=len(spec.get('lakes', [])),
                                      lake_area=[lake['area_m2'] for lake in spec.get('lakes', [])]),
                                 ensure_ascii=False))
                return 0
            record_layout_try(job, seed, 'checks')
            tried.append(seed)
            nxt = next_layout_seed(job)
            if nxt is None:
                print(json.dumps(dict(ok=False, reason='exhausted', tried=tried), ensure_ascii=False))
                return 1
            bind_job_layout(job, nxt, layouts)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(main())
