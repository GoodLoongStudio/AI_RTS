"""Compiled grid kernels. No fast-math: costs and corner rules stay exact."""
import heapq
import math

import numpy as np
from numba import njit


@njit(cache=True, nogil=True)
def shortest_paths(p, si, sj, ti, tj):
    h, w = p.shape
    dist = np.full((h, w), np.inf)
    prev = np.full((h, w), -1, np.int32)
    if not p[si, sj]:
        return dist, prev
    dist[si, sj] = 0.
    queue = [(0., si, sj)]
    directions = ((-1, -1), (0, -1), (1, -1), (-1, 0),
                  (1, 0), (-1, 1), (0, 1), (1, 1))
    while queue:
        cost, i, j = heapq.heappop(queue)
        if cost > dist[i, j] + 1e-12:
            continue
        if i == ti and j == tj:
            break
        for di, dj in directions:
            ni, nj = i + di, j + dj
            if ni < 0 or nj < 0 or ni >= h or nj >= w or not p[ni, nj]:
                continue
            diagonal = di != 0 and dj != 0
            if diagonal and (not p[i + di, j] or not p[i, j + dj]):
                continue
            nd = cost + (math.sqrt(2.) if diagonal else 1.)
            if nd < dist[ni, nj] - 1e-12:
                dist[ni, nj] = nd
                prev[ni, nj] = i*w+j
                heapq.heappush(queue, (nd, ni, nj))
    return dist, prev


@njit(cache=True, nogil=True)
def line_field(points, h, w):
    dist = np.full((h, w), np.inf)
    arc = np.zeros((h, w))
    for i in range(h):
        z = i + .5
        for j in range(w):
            x = j + .5
            cumulative = 0.
            for k in range(len(points)-1):
                ax, az = points[k]
                dx = points[k+1, 0] - ax
                dz = points[k+1, 1] - az
                l2 = dx*dx + dz*dz
                if l2 < 1e-12:
                    continue
                length = math.sqrt(l2)
                t = min(1., max(0., ((x-ax)*dx + (z-az)*dz)/l2))
                distance = math.hypot(x-(ax+dx*t), z-(az+dz*t))
                if distance < dist[i, j]:
                    dist[i, j] = distance
                    arc[i, j] = cumulative + t*length
                cumulative += length
    return dist, arc


def warmup():
    shortest_paths(np.ones((3, 3), dtype=np.bool_), 0, 0, -1, -1)
    line_field(np.array([[0., 0.], [2., 2.]]), 3, 3)
