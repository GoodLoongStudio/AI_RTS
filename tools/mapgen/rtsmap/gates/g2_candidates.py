"""Deterministic candidate workers; start with one, parallelize retries."""
import atexit
import os
from concurrent.futures import ProcessPoolExecutor
try:  # 3.8+ 在包命名空间导出；更早版本只存在于子模块
    from concurrent.futures import BrokenProcessPool
except ImportError:  # pragma: no cover - 取决于本机 Python 版本
    from concurrent.futures.process import BrokenProcessPool

from ..rng import gate_rng

_pool = None
# worker 进程被操作系统杀掉（本机内存紧张时实测发生）后 ProcessPoolExecutor 会
# 永久判死 —— 任其抛出会让整张图变成"未生成"。置此标志后改走串行：慢几分钟，
# 但至少出图。见 candidates() 的降级分支。
_pool_broken = False


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
    global _pool, _pool_broken
    limit = int(params['layout_attempts'])
    # 各轮候选**一次性全并行**，按 index 顺序取结果（确定性不变）：
    # 改前是「第 0 轮串行跑 + 其余按 3 个一批」，4 轮要 3 个批次；
    # 现在一次提交 4 个 ⇒ 总耗时≈单轮（实测 8.5s → 约 4s）。
    workers = max(1, min(limit, int(params.get('candidate_workers', limit)), _worker_cap()))
    if workers <= 1:
        for attempt in range(limit):
            yield evaluate(seed, stream, attempt, starts, params)
        return
    if _pool_broken:
        # 本进程内曾有过 worker 被杀：不再并行，直接串行跑完（结果顺序与结果本身不变）。
        for attempt in range(limit):
            yield evaluate(seed, stream, attempt, starts, params)
        return
    if _pool is None:
        _pool = ProcessPoolExecutor(max_workers=workers, initializer=_initialize)
    step = max(1, int(getattr(_pool, "_max_workers", workers) or workers))
    for start in range(0, limit, step):
        window = list(range(start, min(limit, start + workers)))
        # Always select by candidate index, never completion order.
        # submit 本身也可能抛 BrokenProcessPool（池在更早的时刻就已经坏了），
        # 所以提交与取结果要一起包住，只包 result() 等于没包。
        try:
            futures = [_pool.submit(evaluate, seed, stream, k, starts, params)
                       for k in window]
            results = [f.result() for f in futures]
        except BrokenProcessPool:
            # worker 进程被系统杀掉（本机内存不足时实测：几分钟前还能并行的
            # 任务，之后报 "A child process terminated abruptly"）。此时池已
            # 永久不可用，若照旧抛出，整张图会被判成"未生成"——用户看到的
            # 就是一片无用记录。改为就地串行补算本批候选，并置标志让后续批次
            # 不再并行：慢，但确定出图。
            _pool_broken = True
            try:
                shutdown()
            except Exception:
                # 坏死的池拖垮时也可能在 shutdown 里报错：无论如何把引用清掉，
                # 后续候选都走上面的串行分支。
                _pool = None
            results = [evaluate(seed, stream, k, starts, params)
                       for k in range(start, min(limit, start + workers))]
        for result in results:
            yield result
