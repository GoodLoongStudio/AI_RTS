"""尺寸统一后的落点几何口径（2026-09-29）。

背景：2026-09-27 把建筑 footprint 从 2.0 放大到 6.0~9.8 米，而协调器侧的落点判据
是写死米数的近似（"离己方实体 ≤8m 就算看得见"、"4/6/8m 环"、"后退 3/5/7m"）。
近似与权威端真实判据（`GodotStructurePlacementWorldPort`：整圈 footprint 都要被
`sight + 2m` 覆盖，且不得与既有建筑压盖）脱钩后，副官产出的每个点都注定被拒成
`NotVisible` / `Occupied` / `SurfaceNotBuildable` —— 表现就是"AI 副官不造建筑"。
本组用例把"落点判据必须由 footprint 与视野推导"固化下来。
"""
from __future__ import annotations

import math
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import placement  # noqa: E402


def _base(x=0.0, z=0.0, sight=10.0, radius=7.0):
    return {"pos": [x, 0.0, z], "sight": sight, "radius": radius}


class VisionCeilingTest(unittest.TestCase):
    def test_ceiling_shrinks_with_footprint(self):
        """同一座视野 10m 的基地：小炮塔还能贴脸，大车厂的可建环被压到 5.35m。"""
        revealers = [placement.point_geometry(_base())]
        self.assertAlmostEqual(placement.vision_ceiling(revealers, 2.0),
                               10.0 + placement.SIGHT_COMPENSATION_M - 2.0)
        self.assertAlmostEqual(placement.vision_ceiling(revealers, 6.65),
                               10.0 + placement.SIGHT_COMPENSATION_M - 6.65)

    def test_legacy_proxy_kept_when_no_sight_data(self):
        """裸坐标调用方（没有视野字段）维持旧近似，不被这次改动改写结果。"""
        self.assertTrue(placement.within_vision([7.0, 0.0], [[0.0, 0.0]]))
        self.assertFalse(placement.within_vision([9.0, 0.0], [[0.0, 0.0]]))
        self.assertAlmostEqual(
            placement.vision_ceiling([placement.point_geometry([0.0, 0.0])], 6.65),
            placement.VISION_SAFE_RADIUS_M)


class SpotIssueFootprintTest(unittest.TestCase):
    def test_vision_is_a_product_constraint_not_only_an_authority_rejection(self):
        """权威端 02-29 取消了 `NotVisible`，但协调器**仍**不许在未探明处盲建。

        这是一条产品约束（`test_no_second_base_when_far_resource_is_unseen` 等 7 条用例
        钉着"看不见的远方不能选落点"），去掉它只会让副官在未开图的地方下子基地 ——
        权威端现在还会接受，于是从"被拒"变成"真建错地方"。这里把这个口径钉住。
        """
        home = (104.0, 104.0)
        spot = [110.0, 104.0]     # 离基地 6m：footprint 6.65 在这里超出基地视野
        revealers = [_base(x=home[0], z=home[1])]
        self.assertTrue(placement.AUTHORITY_CHECKS_VISION)
        self.assertEqual(
            placement.spot_issue(spot, [208.0, 208.0], revealers, footprint=6.65),
            placement.REJECT_VISION)
        # 视野判据本身按权威端旧公式换算：d + footprint ≤ sight + 补偿。
        self.assertAlmostEqual(placement.vision_ceiling(revealers, 6.65),
                               10.0 + placement.SIGHT_COMPENSATION_M - 6.65)

    def test_footprint_must_not_overlap_anchor_building(self):
        # 视野给足，只剩"压盖"这一维在判：与半径 7.0 的基地相切需要 7.0+1.0=8.0m。
        revealers = [_base(x=104.0, z=104.0, sight=40.0)]
        self.assertEqual(
            placement.spot_issue([110.0, 108.0], [208.0, 208.0], revealers,
                                 footprint=1.0),
            placement.REJECT_OCCUPANCY)
        self.assertIsNone(
            placement.spot_issue([112.0, 112.0], [208.0, 208.0], revealers,
                                 footprint=1.0))

    def test_bound_margin_follows_footprint(self):
        """footprint 9.8 的矿场中心离边 5m 已经压出地图，必须判越界。"""
        revealers = [_base(x=104.0, z=104.0, sight=40.0)]
        self.assertEqual(
            placement.spot_issue([5.0, 104.0], [208.0, 208.0], revealers, footprint=9.8),
            placement.REJECT_GEOMETRY)


class RingBandTest(unittest.TestCase):
    def test_band_is_empty_when_the_site_cannot_be_revealed(self):
        """只有基地视野（10+2）而 footprint 6.65：环带下界 13.65 > 视野上界 5.35 → 无解。

        这是**真实结论**（要么先开图、要么先造小建筑），协调器必须据此不发命令，
        而不是像过去那样每轮硬挤一个注定被拒的坐标。
        """
        self.assertEqual(placement.build_ring_band([_base()], 7.0, 6.65), ())

    def test_vision_wide_enough_is_capped_by_the_adjacency_gap(self):
        """视野不再是瓶颈时，环带上界改由权威端的相邻上限（相切 + 6m）掐住。"""
        band = placement.build_ring_band([_base(sight=40.0)], 7.0, 6.65)
        self.assertTrue(band, "视野足够时应给出环带")
        for radius in band:
            self.assertGreaterEqual(radius, 13.65)          # 不与基地压盖
            self.assertLessEqual(radius, 13.65 + placement.ADJACENCY_GAP_M)
        self.assertLess(band[-1], 13.65 + placement.ADJACENCY_GAP_M + 0.5)

    def test_unknown_footprint_falls_back_to_legacy_rings(self):
        self.assertEqual(placement.build_ring_band([_base()], 0.0, 0.0), (4.0, 6.0, 8.0))


class CandidateSpotsInvariantTest(unittest.TestCase):
    def test_every_returned_spot_is_buildable_for_that_footprint(self):
        home = (104.0, 104.0)
        revealers = [_base(x=home[0], z=home[1], sight=34.0)]
        spots = placement.candidate_spots(
            home[0], home[1], bounds=[208.0, 208.0], own_points=revealers,
            footprint=6.65, anchor_radius=7.0)
        self.assertTrue(spots, "视野 34m 的基地周围应能放下车厂")
        for spot in spots:
            self.assertIsNone(placement.spot_issue(
                spot, [208.0, 208.0], revealers, footprint=6.65))
            # 环带下界：不与锚点建筑圆心贴合
            self.assertGreater(math.hypot(spot[0] - home[0], spot[1] - home[1]),
                               13.65 - 0.05)


class RetreatSpotFootprintTest(unittest.TestCase):
    def test_retreat_escapes_the_anchor_footprint(self):
        """footprint 6.65 时后退量必须叠加占地半径，否则退 3m 还压在基地上。"""
        revealers = [_base(x=104.0, z=104.0, sight=40.0)]
        spot = placement.retreat_spot(104.0, 104.0, bounds=[208.0, 208.0],
                                      own_points=revealers, footprint=6.65)
        self.assertIsNotNone(spot)
        self.assertGreater(math.hypot(spot[0] - 104.0, spot[1] - 104.0), 6.65)


if __name__ == "__main__":
    unittest.main()
