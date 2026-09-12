"""Deterministic tactical position scoring for model guidance.

The module never claims terrain cover without a terrain provider. Callers may
inject a visibility/cover function from the game runtime; otherwise cover is
explicitly ``None`` and the score remains explainable.
"""
from __future__ import annotations

import math
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

Point = Tuple[float, float]
CoverProvider = Callable[[Point, Point], Optional[float]]


def _point(value: Sequence[float]) -> Point:
    if len(value) < 2:
        raise ValueError("point needs x,z")
    x, z = float(value[0]), float(value[1])
    if not (math.isfinite(x) and math.isfinite(z)):
        raise ValueError("point must be finite")
    return x, z


def score_position(
    position: Sequence[float],
    origin: Sequence[float],
    enemies: Iterable[Dict],
    friendlies: Iterable[Dict],
    sight_range: float,
    cover_provider: Optional[CoverProvider] = None,
) -> Dict:
    """Score one candidate position using deterministic geometric features."""
    pos, start = _point(position), _point(origin)
    distance = math.dist(start, pos)
    enemy_data = []
    for enemy in enemies:
        try:
            enemy_pos = _point(enemy.get("pos", ()))
        except (TypeError, ValueError):
            continue
        enemy_range = float(enemy.get("sight_range", enemy.get("range", 0)) or 0)
        enemy_distance = math.dist(enemy_pos, pos)
        enemy_data.append((enemy_distance, enemy_range, enemy_pos))
    enemy_los_count = sum(1 for distance_to_enemy, enemy_range, _ in enemy_data
                          if enemy_range > 0 and distance_to_enemy <= enemy_range)
    exposure = min(1.0, enemy_los_count / max(1, len(enemy_data))) if enemy_data else 0.0
    support = 0.0
    friendly_count = 0
    for friendly in friendlies:
        try:
            friendly_pos = _point(friendly.get("pos", ()))
        except (TypeError, ValueError):
            continue
        friendly_count += 1
        if math.dist(friendly_pos, pos) <= max(0.0, float(sight_range)):
            support += 1.0
    friendly_support = support / max(1, friendly_count)
    cover = None
    if cover_provider is not None:
        values = [cover_provider(pos, enemy_pos) for _, _, enemy_pos in enemy_data]
        values = [float(value) for value in values if value is not None and math.isfinite(float(value))]
        if values:
            cover = max(0.0, min(1.0, sum(values) / len(values)))
    # Cover is deliberately neutral when unavailable; exposure remains visible.
    cover_term = cover if cover is not None else 0.0
    score = (0.45 * (1.0 - exposure) + 0.30 * cover_term +
             0.20 * friendly_support - 0.05 * min(1.0, distance / 100.0))
    return {
        "position": [pos[0], pos[1]],
        "cover_score": cover,
        "exposure_score": round(exposure, 4),
        "friendly_fire_support": round(friendly_support, 4),
        "enemy_los_count": enemy_los_count,
        "movement_cost": round(distance, 4),
        "score": round(score, 4),
    }


def rank_positions(
    candidates: Iterable[Sequence[float]], origin: Sequence[float],
    enemies: Iterable[Dict], friendlies: Iterable[Dict], sight_range: float,
    cover_provider: Optional[CoverProvider] = None,
) -> List[Dict]:
    results = [score_position(candidate, origin, enemies, friendlies,
                              sight_range, cover_provider)
               for candidate in candidates]
    return sorted(results, key=lambda item: (-item["score"], item["movement_cost"],
                                             item["position"][0], item["position"][1]))
