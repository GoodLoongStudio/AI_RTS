"""Deterministic candidate workers; start with one, parallelize retries."""
import atexit
import os
from concurrent.futures import ProcessPoolExecutor

from ..rng import gate_rng

_pool = None


def evaluate(seed, stream, attempt, starts, params):
    from . import g2_layout as g
    from ..pathing import _cached_line_field
    _cached_line_field.cache_clear()
    rng = gate_rng(seed, 'G2', stream if attempt == 0 else f'{stream}|candidate={attempt}')
    try:
        geom = g.build_geometry(starts, g.polar_order(starts), params, rng)
    except ValueError as error:
        return {'attempt': attempt + 1, 'rejected': str(error)}, None
    keys = g.build_keypoints(starts, geom['exp_anchors'], geom['gap_centers'],
                             plateau_centers=[p['center'] for p in geom['plateaus']])
    blocking, retries, connected = g.build_with_retry(starts, g.polar_order(starts), geom, keys, params, rng)
    role, region = g.assign_role_region(geom, blocking, starts)
    acc = g.acceptance(blocking, role, geom['lanes'], starts, keys, params, geom)
    record = {'attempt': attempt + 1, 'failed_checks': [k for k, v in acc['checks'].items() if not v]}
    return record, (geom, keys, blocking, retries, connected, role, region, acc, attempt + 1)


def _initialize():
    from ..pathing_native import warmup
    warmup()


def shutdown():
    global _pool
    if _pool is not None:
        _pool.shutdown(wait=True, cancel_futures=True)
        _pool = None


atexit.register(shutdown)


def candidates(seed, stream, starts, params):
    global _pool
    limit = int(params['layout_attempts'])
    yield evaluate(seed, stream, 0, starts, params)
    workers = min(int(params.get('candidate_workers', 3)), max(1, (os.cpu_count() or 4)//8))
    if workers <= 1:
        for attempt in range(1, limit):
            yield evaluate(seed, stream, attempt, starts, params)
        return
    if _pool is None:
        _pool = ProcessPoolExecutor(max_workers=workers, initializer=_initialize)
    for start in range(1, limit, workers):
        futures = [_pool.submit(evaluate, seed, stream, k, starts, params)
                   for k in range(start, min(limit, start+workers))]
        # Always select by candidate index, never completion order.
        results = [f.result() for f in futures]
        for result in results:
            yield result
