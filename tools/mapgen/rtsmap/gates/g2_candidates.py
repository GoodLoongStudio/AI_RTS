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


def _worker_cap():
    """并行度上限：每 4 个逻辑核放 1 个 worker（24 核 → 6）。"""
    return max(1, (os.cpu_count() or 4) // 4)


def ensure_pool(limit=4):
    """预热候选进程池（供 serve 启动后在后台线程调用）。

    ProcessPoolExecutor 的 worker 是**懒启动**的：只建 executor 不会 spawn 任何
    进程。这里额外提交 n 个 warmup 任务，把全部 worker 拉起来 —— 每个 worker
    要各自 import numpy/scipy 并 warmup 原生寻路（实测首次生成 9.8s，预热后 4.9s）。
    预热失败不影响正常生成（只是慢一点）。
    """
    global _pool
    if _pool is None:
        workers = max(1, min(int(limit), _worker_cap()))
        _pool = ProcessPoolExecutor(max_workers=workers, initializer=_initialize)
    try:
        pool = _pool
        count = max(1, int(getattr(pool, "_max_workers", 1) or 1))
        for _ in range(count):
            pool.submit(_initialize)
    except Exception:
        pass
    return _pool


def candidates(seed, stream, starts, params):
    global _pool
    limit = int(params['layout_attempts'])
    # 各轮候选**一次性全并行**，按 index 顺序取结果（确定性不变）：
    # 改前是「第 0 轮串行跑 + 其余按 3 个一批」，4 轮要 3 个批次；
    # 现在一次提交 4 个 ⇒ 总耗时≈单轮（实测 8.5s → 约 4s）。
    workers = max(1, min(limit, int(params.get('candidate_workers', limit)), _worker_cap()))
    if workers <= 1:
        for attempt in range(limit):
            yield evaluate(seed, stream, attempt, starts, params)
        return
    if _pool is None:
        _pool = ProcessPoolExecutor(max_workers=workers, initializer=_initialize)
    step = max(1, int(getattr(_pool, "_max_workers", workers) or workers))
    for start in range(0, limit, step):
        futures = [_pool.submit(evaluate, seed, stream, k, starts, params)
                   for k in range(start, min(limit, start+workers))]
        # Always select by candidate index, never completion order.
        results = [f.result() for f in futures]
        for result in results:
            yield result
