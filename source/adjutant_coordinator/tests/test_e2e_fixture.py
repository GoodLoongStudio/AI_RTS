# -*- coding: utf-8 -*-
"""守门：`e2e_dual_layer` 的**独立测试配置**必须与正式表结构对齐。

## 为什么需要这条（2026-09-13 实测）

`e2e_dual_layer.py` 用 `--balance-config` / `--assets-manifest` 起**独立对局**，
好处是"动态规则"能被真实验证。但这两份夹具是 2026-09-07 的快照，之后游戏新增了
`apc` / `heavy_tank` / `transport_truck`（以及 `apc_autocannon` 武器）——
正式表的 Catalog 校验**要求这些定义齐全**，缺一个就：

    [BalanceConfigRuntime] 平衡配置加载失败 → 配置降级继续启动

后果不是"E2E 报错说夹具旧了"，而是**E2E 的 6 项规则检查静默全红**（规则视图不可导出、
新增内容看不见、成本变更看不见…），看起来像"副官功能坏了"。第二轮又报
`$.unitAssets: 实体类型 apc 缺少 unit scene 映射`（资产清单同样腐烂）。

所以：**主表新增定义 → 这条测试立刻红灯**，不让它变成"跑起来才发现"。
"""

import io
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MAIN_BALANCE = os.path.join(PROJECT, "config", "balance", "demo.balance.v1.json")
E2E_BALANCE = os.path.join(PROJECT, "config", "balance", "adjutant-e2e.balance.v1.json")
MAIN_ASSETS = os.path.join(PROJECT, "config", "godot", "demo.assets.v1.json")
E2E_ASSETS = os.path.join(PROJECT, "config", "godot", "adjutant-e2e.assets.v1.json")

BALANCE_SECTIONS = (("unitTypes", "id"), ("weapons", "id"), ("warheads", "id"),
                    ("constructions", "id"), ("productions", "id"))
ASSET_SECTIONS = (("unitAssets", "unitTypeId"), ("weaponAssets", "weaponId"))


def load(path):
    with io.open(path, encoding="utf-8") as handle:
        return json.load(handle)


class E2eFixtureParityTest(unittest.TestCase):
    def test_fixture_files_exist(self):
        for path in (MAIN_BALANCE, E2E_BALANCE, MAIN_ASSETS, E2E_ASSETS):
            self.assertTrue(os.path.exists(path), "缺少 %s" % path)

    def test_balance_fixture_covers_every_required_definition(self):
        main_table = load(MAIN_BALANCE)
        e2e = load(E2E_BALANCE)
        missing = {}
        for section, key in BALANCE_SECTIONS:
            known = {item.get(key) for item in e2e.get(section) or []}
            gap = [item.get(key) for item in main_table.get(section) or []
                   if item.get(key) not in known]
            if gap:
                missing[section] = gap
        self.assertEqual(missing, {}, "e2e 平衡夹具缺定义 → Catalog 会降级、E2E 静默全红：%s"
                         % missing)

    def test_asset_fixture_covers_every_required_scene(self):
        main_assets = load(MAIN_ASSETS)
        e2e = load(E2E_ASSETS)
        missing = {}
        for section, key in ASSET_SECTIONS:
            known = {item.get(key) for item in e2e.get(section) or []}
            gap = [item.get(key) for item in main_assets.get(section) or []
                   if item.get(key) not in known]
            if gap:
                missing[section] = gap
        self.assertEqual(missing, {}, "e2e 资产夹具缺 scene 映射 → 同样会让 Catalog 降级：%s"
                         % missing)

    def test_fixture_keeps_its_dynamic_rules_intent(self):
        """夹具的**测试意图**不能被"对齐主表"冲掉：scout 新增、tank 成本 555。"""
        e2e = load(E2E_BALANCE)
        types = {item.get("id") for item in e2e.get("unitTypes") or []}
        main_types = {item.get("id") for item in load(MAIN_BALANCE).get("unitTypes") or []}
        self.assertIn("scout", types, "e2e 夹具必须保留新增内容 scout")
        self.assertNotIn("scout", main_types, "scout 不该出现在正式平衡表里")
        tank = next((item for item in e2e.get("productions") or []
                     if item.get("id") == "tank"), None)
        self.assertIsNotNone(tank, "e2e 夹具必须有 tank 生产定义")
        cost = sum(int(piece.get("amount", 0)) for piece in tank.get("cost") or [])
        self.assertEqual(cost, 555, "e2e 夹具的 tank 成本必须是 555（动态规则验证用）")


if __name__ == "__main__":
    unittest.main()
