# -*- coding: utf-8 -*-
"""局内加成窄契约：排列、evidence、规则地板、不走 dispatch。"""

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import augment_rank, nodes, observation_view  # noqa: E402
from adjutant_coordinator.graph.rules_fallback import army_threshold_for_augments  # noqa: E402


OFFER = [
    {"id": "aug_cash_drop", "tag": "economy", "rarity": "silver",
     "effect": {"type": "resource_grant"}},
    {"id": "aug_sharpened", "tag": "military", "rarity": "silver",
     "effect": {"type": "damage_mult"}},
    {"id": "aug_wide_eyes", "tag": "scout", "rarity": "gold",
     "effect": {"type": "sight_mult"}},
]


class AugmentRankContractTest(unittest.TestCase):
    def test_rules_floor_has_evidence_and_no_live_pretend(self):
        ranked = augment_rank.rank_offer({
            "offer": OFFER,
            "facts": {"army_count": 1, "balance_a": 80, "enemy_count": 0, "structure_count": 1},
            "profile": {},
        }, live=None)
        self.assertEqual(ranked["source"], "rules")
        self.assertEqual(len(ranked["order"]), 3)
        self.assertTrue(augment_rank.is_permutation(ranked["order"],
                                                    ["aug_cash_drop", "aug_sharpened", "aug_wide_eyes"]))
        for row in ranked["reasons"]:
            self.assertTrue(row["evidence"], row)
            self.assertTrue(augment_rank.evidence_ok(row["evidence"]), row)

    def test_live_must_be_permutation_or_fallback(self):
        floor = augment_rank.rank_offer({"offer": OFFER}, live=None)
        bad = augment_rank.rank_offer({"offer": OFFER}, live={
            "order": ["aug_invented", "aug_cash_drop", "aug_sharpened"],
            "reasons": [],
        })
        self.assertEqual(bad["source"], floor["source"])
        self.assertEqual(bad["order"], floor["order"])

    def test_live_without_evidence_is_rejected(self):
        floor = augment_rank.rank_offer({"offer": OFFER}, live=None)
        rejected = augment_rank.rank_offer({"offer": OFFER}, live={
            "order": ["aug_cash_drop", "aug_sharpened", "aug_wide_eyes"],
            "reasons": [
                {"id": "aug_cash_drop", "text": "好", "evidence": []},
                {"id": "aug_sharpened", "text": "好", "evidence": ["facts.army_count"]},
                {"id": "aug_wide_eyes", "text": "好", "evidence": ["facts.enemy_count"]},
            ],
        })
        self.assertEqual(rejected["order"], floor["order"])

    def test_accepted_live_keeps_star(self):
        live = {
            "order": ["aug_sharpened", "aug_cash_drop", "aug_wide_eyes"],
            "reasons": [
                {"id": "aug_sharpened", "text": "缺兵", "evidence": ["facts.army_count"]},
                {"id": "aug_cash_drop", "text": "缺钱", "evidence": ["facts.balance_a"]},
                {"id": "aug_wide_eyes", "text": "缺视野", "evidence": ["facts.enemy_count"]},
            ],
        }
        ranked = augment_rank.rank_offer({"offer": OFFER}, live=live)
        self.assertEqual(ranked["source"], "live")
        self.assertEqual(ranked["starred_id"], "aug_sharpened")

    def test_owned_tags_from_tactical(self):
        tactical = {"augments": {"owned": [{"id": "aug_cash_drop", "tag": "economy"}]}}
        self.assertEqual(observation_view.owned_augment_tags(tactical), ["economy"])
        self.assertEqual(army_threshold_for_augments(4, tactical), 5)
        military = {"augments": {"owned": [{"id": "aug_warpath", "tag": "military"}]}}
        self.assertEqual(army_threshold_for_augments(4, military), 3)

    def test_dispatch_module_never_sends_augment_ops(self):
        from pathlib import Path
        nodes_src = Path(nodes.__file__).read_text(encoding="utf-8")
        rank_src = Path(augment_rank.__file__).read_text(encoding="utf-8")
        self.assertNotIn("augment_pick", nodes_src)
        self.assertNotIn('"op": "augment_recommend"', nodes_src)
        self.assertNotIn("node_dispatch_to_godot", rank_src)
        self.assertNotIn('"op": "adjutant_intent"', rank_src)
        self.assertNotIn('"op": "augment_pick"', rank_src)

    def test_grant_amount_drives_ranking_for_every_tag(self):
        """额度加分必须与 tag 无关。

        护栏来源：`_grant_bonus` 曾被写进 `tag == "economy"` 分支，导致
        construction 标签的「工程备料」同样给 5000 却拿不到权重，副官照旧
        把它排末位。两份实现彼此一致也发现不了这个错——只有断言「谁该在前」
        才能抓到。
        """
        facts = {"army_count": 2, "balance_a": 9000, "enemy_count": 1, "structure_count": 4}
        for tag in ("economy", "construction", "scout", "military"):
            # ⚠️ 小额牌必须放在**前面**。同 tag 同稀有度下若额度加分缺失，两张牌
            # 分数完全打平，稳定排序会保留输入顺序 —— 把小额牌放前面，缺少加分
            # 时它就会被顶到首位，断言才真的会红（放后面则是假绿，已实测踩过）。
            ranked = augment_rank.rank_offer({
                "offer": [
                    {"id": "aug_probe_small", "tag": tag, "rarity": "silver",
                     "effect": {"type": "resource_grant", "resource_a": 250}},
                    {"id": "aug_probe_big", "tag": tag, "rarity": "silver",
                     "effect": {"type": "resource_grant", "resource_a": 5000}},
                ],
                "facts": dict(facts),
                "profile": {},
            }, live=None)
            self.assertEqual(ranked["order"][0], "aug_probe_big", tag)
            self.assertEqual(ranked["starred_id"], "aug_probe_big", tag)

    def test_godot_ranker_shares_thresholds(self):
        """双实现同口径：Godot 侧常量必须与本模块同名常量数值一致。"""
        from pathlib import Path
        path = (Path(__file__).resolve().parents[3]
                / "source" / "match" / "augments" / "AugmentRanker.gd")
        self.assertTrue(path.is_file(), f"找不到 Godot 排序器 {path}")
        text = path.read_text(encoding="utf-8")
        for name in ("LOW_BALANCE_A", "GRANT_UNIT_A", "GRANT_BONUS_CAP"):
            expected = getattr(augment_rank, name)
            self.assertRegex(
                text, rf"const\s+{name}\s*:=\s*{expected}\b",
                f"Godot 侧 {name} 必须同为 {expected}；只改一边即分叉",
            )

    def test_ties_keep_input_order(self):
        """平局必须保持输入序。

        这是**显式契约**，不是「碰巧」：两侧地板都有可能被换掉排序实现。
        Godot 的 `Array.sort_custom` 官方不保证稳定（2026-09-15 实测同分时
        n≤16 恰好保序、n=32 起就开始乱），Python 的 `list.sort` 稳定但同样
        不该被当作契约来源。Godot 侧的这条断言在该 bug 存在时是红的（n=32
        首位会变成最后一张），本侧是契约锁。
        """
        n = 32
        offer = [
            {"id": f"aug_probe_{i:03d}", "tag": "scout", "rarity": "silver", "effect": {}}
            for i in range(n)
        ]
        ranked = augment_rank.rank_offer({
            "offer": offer,
            "facts": {"army_count": 2, "balance_a": 5000, "enemy_count": 1, "structure_count": 2},
            "profile": {},
        }, live=None)
        self.assertEqual(ranked["order"], [row["id"] for row in offer],
                         "同分牌必须保持输入序（平局键缺失即分叉）")

    def test_godot_ranker_has_explicit_tiebreak(self):
        """Godot 侧的平局键必须存在——否则两个地板会在平局上分叉且毫无报错。

        本侧跑不了 Godot，所以这里做**静态**锁定；真正的运行期红/绿由
        `tests/automated/MatchAugmentSmokeTest.gd::_test_ranker_ties_keep_input_order`
        负责（该断言在平局键缺失时实测为红）。
        """
        from pathlib import Path
        path = (Path(__file__).resolve().parents[3]
                / "source" / "match" / "augments" / "AugmentRanker.gd")
        text = path.read_text(encoding="utf-8")
        # 用 bool + assertTrue 而不是 assertRegex：assertRegex 失败时会把整个源文件
        # 倒进日志，红在哪儿看不出来（实测输出几十行，全是噪声）。
        self.assertTrue(re.search(r'"idx"\s*:\s*idx\b', text),
                        f"{path.name} 必须记录原始下标作为平局次键")
        self.assertTrue(re.search(r'int\(a\["idx"\]\)\s*<\s*int\(b\["idx"\]\)', text),
                        f"{path.name} 比较器必须在同分时按原始下标升序定序")


if __name__ == "__main__":
    unittest.main()
