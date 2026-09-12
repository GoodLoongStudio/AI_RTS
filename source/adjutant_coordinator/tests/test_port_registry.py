# -*- coding: utf-8 -*-
"""端口口径表守门测试（2026-09-13 血案后的"同类不许再犯"）。

## 事故回顾（为什么值得一条测试）

验收脚本把端口和 pidfile 都写成了**面板那一份**：面板固定连 24579，验收用
24579/24582；验收 runner 又把 pidfile 写进面板的 `user://adjutant_logs`。
结果：面板认领了验收的 runner → 面板的 runner 连到验收的对局 → 验收收尾按端口
清理时把面板的 runner 一起杀了。玩家屏幕上看到的是 **"runner 心跳超时"**。

根因是**同一件事（端口）被写了三份**（面板常量 / 验收脚本 / runner 工具）。所以
修法不是"改对那个数字"，而是：**口径收敛到 `config/dev_ports.json` 一份 + 这条守门测试**。
任何一处漂移，本测试立刻红灯。
"""

import io
import json
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
REGISTRY = os.path.join(PROJECT, "config", "dev_ports.json")
PANEL = os.path.join(PROJECT, "source", "ui", "AdjutantButton.gd")
DCS = os.path.join(PROJECT, "source", "net", "DebugControlServer.gd")


def read(path):
    with io.open(path, encoding="utf-8") as handle:
        return handle.read()


def registry():
    return json.loads(read(REGISTRY))


class RegistryShapeTest(unittest.TestCase):
    def test_registry_exists_and_parses(self):
        self.assertTrue(os.path.exists(REGISTRY), "缺少端口口径表 %s" % REGISTRY)
        self.assertIn("roles", registry())

    def test_no_role_shares_a_port(self):
        """一个端口只能有一个角色 —— 共用就是下次撞车的种子。"""
        seen = {}
        for name, port in registry()["roles"].items():
            self.assertNotIn(int(port), seen,
                             "端口 %s 同时属于 %s 与 %s" % (port, seen.get(int(port)), name))
            seen[int(port)] = name

    def test_acceptance_block_does_not_overlap_player_block(self):
        blocks = registry()["reserved_blocks"]
        low, high = blocks["acceptance_only"]
        for name, (start, end) in blocks.items():
            if name == "acceptance_only":
                continue
            self.assertTrue(high < start or low > end,
                            "验收段 %d-%d 与 %s 段 %d-%d 重叠" % (low, high, name, start, end))

    def test_acceptance_roles_stay_inside_the_acceptance_block(self):
        low, high = registry()["reserved_blocks"]["acceptance_only"]
        roles = registry()["roles"]
        for name in ("accept_game_udp", "accept_client_dcs", "accept_server_dcs"):
            self.assertTrue(low <= int(roles[name]) <= high,
                            "%s=%s 不在验收段 %d-%d 内" % (name, roles[name], low, high))

    def test_forbidden_list_is_inside_the_player_block(self):
        """禁列表必须是**玩家的口**（防的就是验收去占它们）。"""
        low, high = registry()["reserved_blocks"]["player_prod"]
        panel_low, panel_high = registry()["reserved_blocks"]["panel_local_test"]
        for port in registry()["forbidden_for_acceptance"]:
            self.assertTrue(low <= int(port) <= high or panel_low <= int(port) <= panel_high,
                            "禁列表里的 %s 不属于玩家/面板段" % port)


class GameSideMatchesRegistryTest(unittest.TestCase):
    def test_dcs_default_ports_match_registry(self):
        """权威端自己的默认口（24568/24579）必须与口径表一致。"""
        text = read(DCS)
        default_port = int(re.search(r"const DEFAULT_PORT\s*:=\s*(\d+)", text).group(1))
        self.assertEqual(default_port, int(registry()["roles"]["game_default_dcs"]),
                         "DebugControlServer.DEFAULT_PORT 与口径表不一致")

    def test_panel_reads_the_registry_instead_of_hardcoding(self):
        """面板必须**从口径表读**候选端口（可以留兜底常量，但不能只有常量）。"""
        text = read(PANEL)
        self.assertIn('PORT_REGISTRY_PATH := "res://config/dev_ports.json"', text,
                      "面板没有指向端口口径表 —— 又回到「各写一份」的老路了")
        self.assertIn("_registry_authority_candidates", text)
        self.assertIn('"panel"', text)
        self.assertIn('"authority_candidates"', text)

    def test_panel_fallback_candidates_are_subset_of_registry(self):
        """兜底列表里的端口必须都在口径表里出现过（不许凭空造一个口）。"""
        text = read(PANEL)
        match = re.search(r"AUTHORITY_PORT_FALLBACK_CANDIDATES: Array = \[(.*?)\]", text,
                          re.S)
        self.assertIsNotNone(match, "找不到面板兜底候选端口列表")
        fallback = [int(value) for value in re.findall(r"\d+", match.group(1))]
        known = set(int(value) for value in registry()["roles"].values())
        known |= set(int(value) for value in registry()["panel"]["authority_candidates"])
        for port in fallback:
            self.assertIn(port, known, "面板兜底候选 %d 不在口径表里" % port)

    def test_panel_prefers_its_own_process_dcs(self):
        """面板在自己的游戏进程里 → **先问本进程 DCS**，而不是去猜端口。

        只断言 `_ensure_authority_port` **函数体内**的先后（文件里别处也可能出现
        `_candidate_ports()`，按全文下标比会误判；这条不变式的范围就是这个函数）。
        """
        text = read(PANEL)
        self.assertIn('/root/DebugControlServer', text)
        marker = "func _ensure_authority_port()"
        self.assertIn(marker, text, "面板没有权威口解析入口")
        body = text[text.index(marker):]
        next_func = body.find("\nfunc ", 1)
        body = body[:next_func] if next_func > 0 else body
        self.assertIn("_candidate_ports()", body, "解析函数里没有候选探测（逻辑被挪走了？）")
        self.assertLess(body.index('/root/DebugControlServer'),
                        body.index("_candidate_ports()"),
                        "面板把「猜端口」排在了「问本进程」前面")


class AcceptanceGuardTest(unittest.TestCase):
    """验收侧的两条硬闸门（脚本里必须真的调用它们）。"""

    ACCEPT = os.path.join(os.path.dirname(PROJECT), "tmp_logs", "campaign_accept",
                          "campaign_accept.py")

    def test_acceptance_script_guards_its_port_and_hud(self):
        if not os.path.exists(self.ACCEPT):
            self.skipTest("验收脚本不在本机（%s）" % self.ACCEPT)
        text = read(self.ACCEPT)
        self.assertIn("check_acceptance_base", text,
                      "验收脚本没有端口硬闸门（越界必须拒跑，不能靠人自觉）")
        self.assertIn("AIRTS_RUNNER_HUD", text,
                      "验收脚本没有隔离 HUD/pidfile —— 会劫持游戏内面板的视角")

    def test_acceptance_default_base_is_inside_its_block(self):
        low, high = registry()["reserved_blocks"]["acceptance_only"]
        self.assertTrue(low <= int(registry()["acceptance"]["base"]) <= high)


if __name__ == "__main__":
    unittest.main()
