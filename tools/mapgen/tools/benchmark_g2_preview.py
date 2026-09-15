"""Generate a fresh matching G1/G2 pair and save honest timing and review images."""
import argparse
import faulthandler
import json
import time
import threading
from pathlib import Path

import psutil

from rtsmap.contract import G1_DEFAULTS, G2_DEFAULTS, GRID_H, GRID_W
from rtsmap.gates import g1_starts, g2_layout
from rtsmap.viz.plots_g2 import overview_from_res, render_overview


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seed', type=int, default=16)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--river-layout', type=int, default=2)
    parser.add_argument('--lakes', type=int, default=0)
    parser.add_argument('--lake-area', type=int, default=None)
    parser.add_argument('--no-river', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    faulthandler.dump_traceback_later(60, repeat=True)
    started = time.perf_counter()
    _, parent = g1_starts.run_one(args.seed, args.out / 'runs', dict(G1_DEFAULTS))
    print('G1', parent['accepted'], parent['starts'], flush=True)
    process = psutil.Process()
    baseline = sum(process.cpu_times()[:2])
    observed = {}
    peak_rss = [0]
    stop = threading.Event()

    def sample():
        while not stop.is_set():
            rss = 0
            for worker in [process, *process.children(recursive=True)]:
                try:
                    observed[worker.pid] = sum(worker.cpu_times()[:2])
                    rss += worker.memory_info().rss
                except psutil.Error:
                    pass
            peak_rss[0] = max(peak_rss[0], rss)
            stop.wait(.05)

    monitor = threading.Thread(target=sample, daemon=True)
    monitor.start()
    t0 = time.perf_counter()
    overrides = dict(G2_DEFAULTS, river_layout=args.river_layout,
            lake_count=args.lakes, river_enabled=int(not args.no_river))
    if args.lake_area is not None:
        overrides['lake_area'] = args.lake_area
    result = g2_layout.run_preview(
        args.seed, args.out / 'runs', overrides,
        on_progress=lambda event: print(round(time.perf_counter()-t0, 3), event, flush=True))
    generation_s = time.perf_counter() - t0
    stop.set()
    monitor.join()
    cpu_s = sum(observed.values()) - baseline
    data = overview_from_res(result)
    render_overview(dict(data, show_routes=False)).save(args.out / 'overview.png')
    render_overview(dict(data, show_routes=True)).save(args.out / 'strategy.png')
    rivers = result['mapspec'].get('rivers', [])
    lakes = result['mapspec'].get('lakes', [])
    report = dict(seed=args.seed, grid=[GRID_W, GRID_H], g2_generation_s=generation_s,
                  total_with_g1_and_images_s=time.perf_counter()-started,
                  under_10_seconds=generation_s < 10,
                  all_pass=result['mapspec']['all_pass'],
                  solid_percent=result['mapspec']['solid_frac']*100,
                  plateaus=len(result['mapspec']['plateaus']),
                  plateau_top_percent=result['mapspec']['strategy_metrics']['plateau_top_fraction']*100,
                  tributaries=sum(len(r.get('tributaries', [])) for r in result['mapspec']['rivers']),
                  river_enabled=bool(not args.no_river), river_layout=(args.river_layout if not args.no_river else 0),
                  river_count=len(rivers), river_widths_m=[round(float(r.get('width', 0)), 2) for r in rivers],
                  lake_count=len(lakes), lake_areas_m2=[round(float(l.get('area_m2', 0)), 2) for l in lakes],
                  logical_cpus=psutil.cpu_count(), physical_cores=psutil.cpu_count(logical=False),
                  sampled_cpu_seconds=cpu_s, average_busy_logical_cpus=cpu_s/generation_s,
                  peak_process_tree_rss_mb=peak_rss[0]/1024**2,
                  failed_checks=[k for k, v in result['mapspec']['checks'].items() if not v],
                  generation=result['mapspec']['generation'])
    (args.out / 'timing.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    faulthandler.cancel_dump_traceback_later()
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
