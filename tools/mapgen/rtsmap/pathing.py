"""寻路与几何：膨胀、BFS/Dijkstra（8 邻域禁穿角）、连通分量、通道宽度测量。"""
import heapq
import math
from dataclasses import dataclass
from functools import lru_cache

import numpy as np
from concurrent.futures import ThreadPoolExecutor
from scipy import ndimage
from .pathing_native import shortest_paths, line_field

from .contract import GRID_H, GRID_W

SQRT2 = math.sqrt(2.0)

# 8 邻域 (di, dj, cost)
NEIGH8 = [
    (-1, -1, SQRT2), (0, -1, 1.0), (1, -1, SQRT2),
    (-1, 0, 1.0), (1, 0, 1.0),
    (-1, 1, SQRT2), (0, 1, 1.0), (1, 1, SQRT2),
]


def dilate8(mask: np.ndarray) -> np.ndarray:
    """1 格 8 邻域膨胀（bool）。地图外不视为 blocking（pad False）。"""
    m = np.asarray(mask, dtype=bool)
    h, w = m.shape
    padded = np.zeros((h + 2, w + 2), dtype=bool)
    padded[1:-1, 1:-1] = m
    out = np.zeros_like(m)
    for dy in range(3):
        for dx in range(3):
            out |= padded[dy:dy + h, dx:dx + w]
    return out


def compute_passable(blocking: np.ndarray) -> np.ndarray:
    """passable = 对 blocking 做 1 格 8 邻域膨胀后取反。返回 u8。"""
    return (~dilate8(np.asarray(blocking) > 0)).astype(np.uint8)


def erode8(mask: np.ndarray) -> np.ndarray:
    """3×3 8 邻域腐蚀（bool）。地图外视为 True（实体），以保留边界实体。"""
    m = np.asarray(mask, dtype=bool)
    h, w = m.shape
    padded = np.ones((h + 2, w + 2), dtype=bool)
    padded[1:-1, 1:-1] = m
    out = np.ones_like(m)
    for dy in range(3):
        for dx in range(3):
            out &= padded[dy:dy + h, dx:dx + w]
    return out


def opening8(mask: np.ndarray) -> np.ndarray:
    """形态学开运算（先腐蚀再膨胀），去掉 1 格宽细丝。"""
    return dilate8(erode8(mask))


def _label8_reference(mask: np.ndarray) -> np.ndarray:
    """普通 8 连通（含对角）分量标号，用于实体块。返回 label（-1=False，0..n-1）。

    与 bfs_components（禁穿角）不同：实体块的对角相接视为同一块。
    """
    m = np.asarray(mask) > 0
    h, w = m.shape
    label = np.full((h, w), -1, dtype=np.int32)
    nbrs = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    comp = 0
    for si in range(h):
        for sj in range(w):
            if not m[si, sj] or label[si, sj] != -1:
                continue
            stack = [(si, sj)]
            label[si, sj] = comp
            while stack:
                i, j = stack.pop()
                for di, dj in nbrs:
                    ni, nj = i + di, j + dj
                    if 0 <= ni < h and 0 <= nj < w and m[ni, nj] and label[ni, nj] == -1:
                        label[ni, nj] = comp
                        stack.append((ni, nj))
            comp += 1
    return label


def _neighbors(i, j, h, w, passable):
    for di, dj, cost in NEIGH8:
        ni, nj = i + di, j + dj
        if ni < 0 or nj < 0 or ni >= h or nj >= w:
            continue
        if not passable[ni, nj]:
            continue
        if di != 0 and dj != 0:  # 禁止穿角：斜向要求两个正交邻格都可走
            if not passable[i + di, j] or not passable[i, j + dj]:
                continue
        yield ni, nj, cost


def _bfs_reference(passable: np.ndarray) -> np.ndarray:
    """8 邻域禁穿角连通分量标号。返回 label（-1 = 不可走，0..n-1 分量）。"""
    p = np.asarray(passable) > 0
    h, w = p.shape
    label = np.full((h, w), -1, dtype=np.int32)
    comp = 0
    for si in range(h):
        for sj in range(w):
            if not p[si, sj] or label[si, sj] != -1:
                continue
            q = [(si, sj)]
            label[si, sj] = comp
            head = 0
            while head < len(q):
                i, j = q[head]
                head += 1
                for ni, nj, _ in _neighbors(i, j, h, w, p):
                    if label[ni, nj] == -1:
                        label[ni, nj] = comp
                        q.append((ni, nj))
            comp += 1
    return label


def _dijkstra_reference(passable: np.ndarray, src_ij, dst_ij=None):
    """8 邻域禁穿角 Dijkstra，斜向代价 √2。

    返回 (dist ndarray（不可达 = inf）, path list[(i,j)] 或 None)。
    """
    p = np.asarray(passable) > 0
    h, w = p.shape
    si, sj = src_ij
    if not p[si, sj]:
        dist = np.full((h, w), np.inf)
        return dist, None
    dist = np.full((h, w), np.inf)
    prev = {}
    dist[si, sj] = 0.0
    pq = [(0.0, si, sj)]
    target = tuple(dst_ij) if dst_ij is not None else None
    while pq:
        d, i, j = heapq.heappop(pq)
        if d > dist[i, j] + 1e-12:
            continue
        if target is not None and (i, j) == target:
            break
        for ni, nj, cost in _neighbors(i, j, h, w, p):
            nd = d + cost
            if nd < dist[ni, nj] - 1e-12:
                dist[ni, nj] = nd
                prev[(ni, nj)] = (i, j)
                heapq.heappush(pq, (nd, ni, nj))
    if target is None:
        return dist, None
    if not math.isfinite(dist[target]):
        return dist, None
    path = [target]
    while path[-1] != (si, sj):
        path.append(prev[path[-1]])
    path.reverse()
    return dist, path


def label8(mask):
    return ndimage.label(np.asarray(mask) > 0, np.ones((3, 3)))[0].astype(np.int32) - 1


def bfs_components(passable):
    # Every legal diagonal has a two-step orthogonal connection; hence the
    # components are exactly those of four-connectivity, without Python BFS.
    return ndimage.label(np.asarray(passable) > 0)[0].astype(np.int32) - 1


def dijkstra(passable, src_ij, dst_ij=None):
    p = np.ascontiguousarray(passable, dtype=np.bool_)
    target = tuple(dst_ij) if dst_ij is not None else (-1, -1)
    dist, prev = shortest_paths(p, int(src_ij[0]), int(src_ij[1]), int(target[0]), int(target[1]))
    if dst_ij is None or not np.isfinite(dist[target]):
        return dist, None
    path = [target]
    while path[-1] != tuple(src_ij):
        path.append(divmod(int(prev[path[-1]]), p.shape[1]))
    path.reverse()
    return dist, path


def distance_fields(passable, sources):
    # Compiled kernels release the GIL, allowing real CPU parallelism.
    with ThreadPoolExecutor(max_workers=min(4, len(sources))) as pool:
        return list(pool.map(lambda src: dijkstra(passable, cell_of(*src))[0], sources))


def path_length(passable, src_ij, dst_ij) -> float:
    dist, _ = dijkstra(passable, src_ij, dst_ij)
    d = dist[dst_ij[0], dst_ij[1]]
    return float(d) if math.isfinite(d) else math.inf


def cell_of(x: float, z: float):
    """连续米坐标 → 格 (i, j)。"""
    return (int(math.floor(z)), int(math.floor(x)))  # (row=i → Z, col=j → X)


def center_of(i: int, j: int):
    """格 → 中心米坐标 (x, z)。"""
    return (j + 0.5, i + 0.5)


def keypoints_connected(passable, key_ij_list) -> bool:
    """关键点集是否全部可走且在同一连通分量。"""
    p = np.asarray(passable) > 0
    for i, j in key_ij_list:
        if not p[i, j]:
            return False
    label = bfs_components(p)
    first = label[key_ij_list[0]]
    return all(label[i, j] == first for i, j in key_ij_list)


# ---------------- 通道宽度测量 ----------------

@dataclass
class LaneSample:
    x: float
    z: float
    nx: float   # 单位法向 X
    nz: float   # 单位法向 Z
    width: float


def lane_samples_along(polyline, step: float = 2.0):
    """沿折线每 step 米取采样点，返回 [(x, z, nx, nz)]（法向 = 段方向旋转 90°）。"""
    pts = [np.array(p, dtype=float) for p in polyline]
    segs = []
    for a, b in zip(pts[:-1], pts[1:]):
        d = b - a
        L = float(np.hypot(d[0], d[1]))
        if L < 1e-9:
            continue
        u = d / L
        n = np.array([-u[1], u[0]])  # 旋转 90°
        segs.append((a, u, n, L))
    out = []
    for a, u, n, L in segs:
        t = 0.0
        while t <= L + 1e-9:
            p = a + u * t
            out.append((float(p[0]), float(p[1]), float(n[0]), float(n[1])))
            t += step
    return out


def _side_clearance(x, z, nx, nz, blocking, cap, step=0.25, sign=1.0):
    """从 (x,z) 沿法向 sign 方向走到第一个 blocking 格的距离（米）。"""
    h, w = blocking.shape
    t = step
    while t <= cap + 1e-9:
        px, pz = x + nx * sign * t, z + nz * sign * t
        if px < 0 or pz < 0 or px >= w or pz >= h:
            return t  # 出图边界按阻断计
        i, j = int(pz), int(px)
        if blocking[i, j] > 0:
            return t
        t += step
    return cap


def lane_min_width(polyline, blocking, step: float = 2.0, cap: float = 30.0):
    """通道最窄宽度：沿折线每 step 米采样，法向两侧到第一个 blocking 的距离之和，取最小。"""
    samples = lane_samples_along(polyline, step)
    widths = []
    for x, z, nx, nz in samples:
        w_l = _side_clearance(x, z, nx, nz, blocking, cap, sign=-1.0)
        w_r = _side_clearance(x, z, nx, nz, blocking, cap, sign=1.0)
        widths.append(min(w_l + w_r, cap))
    if not widths:
        return cap
    return float(min(widths))


def lane_width_profile(polyline, blocking, step: float = 2.0, cap: float = 30.0):
    """返回 LaneSample 列表（供 chokes 图与调试）。"""
    out = []
    for x, z, nx, nz in lane_samples_along(polyline, step):
        w_l = _side_clearance(x, z, nx, nz, blocking, cap, sign=-1.0)
        w_r = _side_clearance(x, z, nx, nz, blocking, cap, sign=1.0)
        out.append(LaneSample(x, z, nx, nz, min(w_l + w_r, cap)))
    return out


def polyline_length(polyline) -> float:
    pts = [np.array(p, dtype=float) for p in polyline]
    total = 0.0
    for a, b in zip(pts[:-1], pts[1:]):
        total += float(np.hypot(*(b - a)))
    return total


def _polyline_field_reference(polyline):
    """向量化：每个格中心到折线的最小距离 dist，及最近投影点处的累计弧长 arc（米）。

    返回 (dist, arc)，均为 (GRID_H, GRID_W)。供变宽度通道雕刻（按 w(arc) 判定）。
    """
    gx = np.arange(GRID_W) + 0.5   # X（列 j）
    gz = np.arange(GRID_H) + 0.5   # Z（行 i）
    xx, zz = np.meshgrid(gx, gz)   # (H, W)
    pts = [np.array(p, dtype=float) for p in polyline]
    dist = np.full((GRID_H, GRID_W), np.inf)
    arc = np.zeros((GRID_H, GRID_W))
    cum = 0.0
    for a, b in zip(pts[:-1], pts[1:]):
        d = b - a
        L2 = float(d @ d)
        L = math.sqrt(L2)
        if L2 < 1e-12:
            continue
        t = np.clip(((xx - a[0]) * d[0] + (zz - a[1]) * d[1]) / L2, 0.0, 1.0)
        px = a[0] + d[0] * t
        pz = a[1] + d[1] * t
        dd = np.hypot(xx - px, zz - pz)
        s_here = cum + t * L
        closer = dd < dist
        dist[closer] = dd[closer]
        arc[closer] = s_here[closer]
        cum += L
    return dist, arc


def polyline_field(polyline):
    key = tuple(tuple(float(c) for c in point) for point in polyline)
    return _cached_line_field(key)


@lru_cache(maxsize=40)
def _cached_line_field(key):
    dist, arc = line_field(np.asarray(key, dtype=np.float64).reshape(-1, 2), GRID_H, GRID_W)
    dist.flags.writeable = False
    arc.flags.writeable = False
    return dist, arc


def dist_to_polyline(x, z, polyline) -> float:
    """点到折线的最小距离（米）。"""
    p = np.array([x, z], dtype=float)
    best = math.inf
    pts = [np.array(q, dtype=float) for q in polyline]
    for a, b in zip(pts[:-1], pts[1:]):
        d = b - a
        L2 = float(d @ d)
        t = 0.0 if L2 < 1e-12 else float(np.clip((p - a) @ d / L2, 0.0, 1.0))
        proj = a + d * t
        best = min(best, float(np.hypot(*(p - proj))))
    return best
