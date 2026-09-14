# -*- coding: utf-8 -*-
"""对局留档的守门测试。

用户 2026-09-13："现在开始，每个对局都有意义，要尽可能把数据留档，我要给高级模型分析。"

所以这里钉住的是**留档本身的可靠性**（不是对局行为）：
① 五类事实都真的落盘（逐条事件 / 每轮世界 / 命令生命周期 / 模型提议 / 决策）；
② 超上限**显式标截断**（分析时看到的"只有前半局"必须是事实，不是静默丢弃）；
③ 摘要（digest）必须把"分析模型第一时间需要的东西"写全：身份/规模/被拒原因/主线里程碑/文件清单；
④ 留档**失败不许影响对局**（写不进去就记账，不抛）。
"""

import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.deploy import match_archive as ma  # noqa: E402


class MatchArchiveTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="airts_archive_")
        self.archive = ma.MatchArchive(self.root, match_id="ce3b85bd-aaaa",
                                      player="Player_0", rules_version="deadbeef",
                                      config={"model": "off"})

    def tearDown(self):
        # 先收尾（关句柄）再删目录：否则 Windows 上会因句柄未关留下 ResourceWarning。
        if not self.archive.closed:
            self.archive.close(status="teardown")
        shutil.rmtree(self.root, ignore_errors=True)

    def _read(self, name):
        path = os.path.join(self.archive.dir, name)
        if not os.path.isfile(path):
            return []
        with open(path, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def test_lines_hit_disk_before_close(self):
        """**强杀也不丢**：写一行就该在磁盘上看到（不许等 close 才落盘）。

        依据（2026-09-13 实测）：验收/收尾用 `taskkill /F` 收 runner，默认 8KB 缓冲下
        已写的行还在内存里 → 进程一被强杀**整份丢失**，表现就是档案里 `rounds.jsonl`
        从未出现（MANIFEST 只能写"runner 未写留档"）。改成行缓冲后这条必须成立。
        """
        self.archive.round_({"server_tick": 321, "balance": 700, "units": [],
                             "enemies": [], "production": [], "lanes": {}, "movement": {}})
        path = os.path.join(self.archive.dir, "rounds.jsonl")
        self.assertTrue(os.path.isfile(path), "行缓冲下文件应立刻存在")
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
        self.assertIn('"server_tick": 321', body,
                      "**没有 close 也必须已经落盘**（否则被强杀就丢档案）")

    def test_all_five_streams_land_on_disk(self):
        self.archive.event({"kind": "damage", "server_tick": 100, "unit": "Unit_1",
                            "amount": 7})
        self.archive.round_({"server_tick": 100, "balance": 500, "units": [{"n": "Unit_1"}],
                             "enemies": [], "production": [], "lanes": {}, "movement": {}})
        self.archive.command({"server_tick": 100, "intent_id": "i-1", "action": "attack",
                              "status": "Rejected", "reason": "WeaponCannotTargetDomain"})
        self.archive.model({"role": "tactics", "method": "propose_task_patch", "ok": True,
                            "latency_ms": 1200, "tick": 100, "proposal": "{\"intents\": []}"})
        self.archive.decision({"kind": "movement_gate", "server_tick": 100, "kept": 0})
        self.archive.timeline("phase", phase="立足", tick=100)
        payload = self.archive.close(status="stopped", extra={"outcome": {"finished": True}})

        self.assertEqual(len(self._read("events.jsonl")), 1)
        self.assertEqual(len(self._read("rounds.jsonl")), 1)
        self.assertEqual(len(self._read("commands.jsonl")), 1)
        self.assertEqual(len(self._read("model.jsonl")), 1)
        self.assertEqual(len(self._read("decisions.jsonl")), 1)
        self.assertTrue(os.path.isfile(os.path.join(self.archive.dir, "digest.md")))
        self.assertEqual(payload["counts"]["events"], 1)
        self.assertEqual(payload["counts"]["commands"], 1)
        self.assertEqual(payload["counts"]["model_calls"], 1)
        self.assertEqual(payload["first_tick"], 100)

    def test_truncation_is_explicit_not_silent(self):
        """超上限 → 停写并**标截断**：分析时看到的必须是事实，不是被悄悄砍掉的档。"""
        original = ma.FILE_LIMIT_BYTES
        ma.FILE_LIMIT_BYTES = 2048
        try:
            for index in range(200):
                self.archive.event({"kind": "damage", "server_tick": index,
                                    "unit": "Unit_1", "pad": "x" * 120})
            payload = self.archive.close(status="stopped")
        finally:
            ma.FILE_LIMIT_BYTES = original
        self.assertIn("events.jsonl", payload["truncated"])
        self.assertLess(len(self._read("events.jsonl")), 200, "超上限后必须停写")

    def test_digest_carries_what_analysis_needs(self):
        self.archive.round_({"server_tick": 600, "balance": 1234,
                             "units": [{"n": "Unit_1", "t": "soldier", "p": [10.0, 7.0],
                                        "hp": 88.0}],
                             "enemies": [{"n": "Unit_5", "t": "tank", "p": [40.0, 40.0],
                                          "hp": 100.0, "seen": 600}],
                             "production": [{"producer": "Unit_0", "queue": 1,
                                             "item": "soldier", "work": "3/10",
                                             "state": "running"}],
                             "coord_hz": 1.9, "elapsed_ms": 300, "scan_hz": 9.1,
                             "snapshot_age_p95": 0.1,
                             "movement": {"allowed": 12, "blocked_reasons": {"threat_too_high": 3},
                                          "ungated": 0, "unsafe_dispatches": 0,
                                          "scout_first_coverage": 0.8},
                             "lanes": {"economy": {"tasks": 3}}})
        self.archive.command({"server_tick": 600, "intent_id": "i-9", "action": "attack",
                              "status": "Rejected",
                              "reason": "当前武器无法攻击该目标所处的域"})
        self.archive.timeline("milestone_done", milestone="M01", tick=600)
        self.archive.model({"role": "tactics", "method": "propose_task_patch", "ok": False,
                            "kind": "ModelTimeout", "latency_ms": 30000, "tick": 600})
        payload = self.archive.close(status="no_active_match", extra={"outcome": {"finished": True}})
        text = self.archive.digest(payload)
        for needle in ("对局档案摘要", "ce3b85bd", "命令（权威层收没收）", "被拒原因",
                       "WeaponCannotTargetDomain" if False else "当前武器无法攻击",
                       "milestone_done", "最后一轮的世界", "明细文件", "模型"):
            self.assertIn(needle, text, "摘要缺 %s" % needle)
        self.assertIn("balance", text.lower() + "balance", "最后一轮世界要含余额")

    def test_write_failure_never_raises(self):
        """留档目录不可写时必须**记账并继续**，不许把异常抛进指挥链。"""
        archive = ma.MatchArchive("\x00bad\x00path", match_id="x", player="p")
        archive.event({"kind": "damage"})
        archive.command({"action": "attack", "status": "Rejected", "reason": "r"})
        payload = archive.close(status="stopped")
        self.assertTrue(payload.get("truncated"), "写不进去要显式标出来")

    def test_campaign_moments_accepts_int_and_list(self):
        """`campaign["interrupts"]` 是**整数计数**（不是列表）—— 按列表遍历会抛 TypeError。

        实测（2026-09-13 真机局 f3arc）：`for key in campaign["interrupts"]` →
        `'int' object is not iterable` → **整轮留档中断**（明细文件全空）。
        """
        self.archive.campaign_moments({"phase": "摸底", "frontier": "M01",
                                       "interrupts": 1, "done": [], "updated_tick": 100})
        self.archive.campaign_moments({"phase": "摸底", "frontier": "M01",
                                       "interrupts": 2, "done": ["M01"], "updated_tick": 200})
        self.archive.campaign_moments({"phase": "立足", "frontier": "M02",
                                       "interrupts": 2, "done": ["M01"], "updated_tick": 300})
        # 列表形态也要能用（兼容旧/新两种摘要）。
        self.archive.campaign_moments({"phase": "立足", "frontier": "M02",
                                       "interrupts": [{"kind": "base_under_attack"}],
                                       "done": ["M01"], "updated_tick": 400})
        payload = self.archive.close(status="stopped")
        kinds = [item["event"] for item in payload["timeline"]]
        self.assertIn("phase", kinds)
        self.assertIn("frontier", kinds)
        self.assertIn("milestone_done", kinds)
        self.assertIn("interrupts", kinds)
        self.assertIn("interrupt", kinds)
        # 幂等：重复同一状态不再追加。
        first = len(payload["timeline"])
        self.archive.campaign_moments({"phase": "立足", "frontier": "M02",
                                       "interrupts": 2, "done": ["M01"], "updated_tick": 500})
        self.assertEqual(len(self.archive._timeline), first)

    def test_dirty_strings_still_land_on_disk(self):
        """游戏侧读来的脏字符串（孤立代理字符）**不许让整档静默变空**。

        实测（2026-09-13 真机局 f3b）：`json.dumps(..., ensure_ascii=False)` 保留 `\\udcxx`，
        写 utf-8 抛 `UnicodeEncodeError`（ValueError 子类）→ 被吞 → 四个明细文件全 0 字节
        且不报错（整整一局的数据白丢）。
        """
        self.archive.event({"kind": "damage", "unit": "Unit_\udcff", "amount": 3})
        self.archive.round_({"server_tick": 1, "note": "坏字符\udc80"})
        self.archive.flush()
        events = self._read("events.jsonl")
        self.assertEqual(len(events), 1, "脏字符串也必须落盘（清洗后写）")
        self.assertTrue(events[0]["unit"].startswith("Unit_"))
        self.assertGreater(os.path.getsize(os.path.join(self.archive.dir, "rounds.jsonl")), 0)

    def test_writes_are_flushed_for_crash_safety(self):
        """留档必须**已落盘**：长跑进程随时可能被打断，不许只在内存缓冲里。"""
        self.archive.round_({"server_tick": 100, "units": []})
        self.archive.flush()
        size = os.path.getsize(os.path.join(self.archive.dir, "rounds.jsonl"))
        self.assertGreater(size, 0, "flush 之后磁盘上必须已经有内容")

    def test_combat_event_context_is_attached_as_inference(self):
        """战斗事件要带上下文：**当时命令它干什么 + 附近有谁**（并标成推断，不做归因）。

        游戏侧受伤信号只带受害者（`MatchSignals.unit_damaged(unit)`），没有攻击者 →
        归档层只能补"位置事实 + 我们自己的命令"，并显式标 `enriched`，不许冒充权威归因。
        """
        units = [{"n": "Unit_7", "t": "soldier", "p": [10.0, 10.0]},
                 {"n": "Unit_9", "t": "tank", "p": [80.0, 80.0]}]
        enemies = [{"unit": "Enemy_2", "unit_type": "infantry", "pos": [14.0, 11.0]}]
        intents = [{"intent_id": "rule-attack-Unit_7", "action": "attack",
                    "unit_ids": ["Unit_7"], "target": {"entity_id": "Enemy_2"},
                    "issued_tick": 900, "state": "active"}]
        enriched = self.archive.enrich_event(
            {"kind": "damage", "unit": "Unit_7", "hp": 40.0, "delta": -12.0,
             "pos": [10.0, 0.0, 10.0], "server_tick": 1000},
            units=units, enemies=enemies, intents=intents)
        self.assertTrue(enriched["enriched"])
        self.assertEqual(enriched["order"]["intent_id"], "rule-attack-Unit_7")
        self.assertEqual(enriched["order"]["action"], "attack")
        self.assertEqual([item["unit"] for item in enriched["nearby_own"]], ["Unit_7"])
        self.assertEqual(enriched["nearby_enemy"][0]["unit"], "Enemy_2")
        self.assertEqual(enriched["nearby_enemy"][0]["dist"], 4.1)
        # 非战斗事件不动（避免把上下文塞满整份档案）。
        plain = self.archive.enrich_event({"kind": "arrival", "unit": "Unit_1"})
        self.assertNotIn("enriched", plain)

    def test_enemy_victim_records_who_we_sent(self):
        """挨打的是敌人 → 记"我们在用谁打它"。

        实测（2026-09-13 f5arc 局）：18 条战斗事件全是**敌人**掉血，`order` 天然为空 ——
        只有 `order` 一条分支时，档案会出现"只看到敌人掉血、看不到谁在打"的盲区。
        """
        intents = [
            {"intent_id": "rule-attack-Unit_2", "action": "attack", "unit_ids": ["Unit_2"],
             "target": {"entity_id": "Enemy_5"}, "state": "active"},
            {"intent_id": "bt-attack-Unit_3", "action": "attack", "unit_ids": ["Unit_3"],
             "target": {"entity_id": "Enemy_5"}, "state": "active"}]
        enriched = self.archive.enrich_event(
            {"kind": "damage", "unit": "Enemy_5", "hp": 30.0, "delta": -8.0,
             "pos": [12.0, 0.0, 12.0]},
            units=[], enemies=[], intents=intents)
        self.assertNotIn("order", enriched, "敌人挨打时不该有我方 order")
        self.assertEqual([item["intent_id"] for item in enriched["attacker_orders"]],
                         ["rule-attack-Unit_2", "bt-attack-Unit_3"])
        self.assertEqual(enriched["attacker_orders"][0]["units"], ["Unit_2"])

    def test_command_lifecycle_merges_graph_timing(self):
        """命令表要有完整生命周期：决定 tick → 下发 tick → 回执（否则"为什么慢"拼不起来）。"""
        self.archive.command({"server_tick": 1000, "intent_id": "i-1", "action": "attack",
                              "status": "Rejected", "reason": "domain"})
        self.archive.command({"server_tick": 1000, "intent_id": "i-2", "action": "move",
                              "status": "Accepted"})
        merged = self.archive.command_lifecycle([
            {"event": "command_timing", "intent_id": "i-1", "generated_tick": 960,
             "received_tick": 1005, "status": "Rejected"},
            {"event": "hud_status", "intent_id": "", "thinking": "x"}])
        self.assertEqual(merged["merged"], 1)
        self.archive.rebuild_from_files()
        payload = self.archive.close(status="stopped")
        rows = {row["intent_id"]: row for row in self._read("commands.jsonl")}
        self.assertEqual(rows["i-1"]["generated_tick"], 960)
        self.assertEqual(rows["i-1"]["received_tick"], 1005)
        self.assertEqual(rows["i-1"]["dispatch_ticks"], 45)
        self.assertNotIn("generated_tick", rows["i-2"], "没合并到的命令不许伪造 lifecycle")
        self.assertEqual(payload["counts"]["commands"], 2)

    def test_schema_document_is_written(self):
        """字段字典必须随档案落盘（分析模型最容易把 Accepted 当完成）。"""
        self.archive.round_({"server_tick": 1})
        self.archive.close(status="stopped")
        with io.open(os.path.join(self.archive.dir, "SCHEMA.md"), encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("Accepted", text)
        self.assertIn("60 tick", text)
        self.assertIn("缺失 ≠ 没发生", text)

    def test_rebuild_from_files_makes_summary_match_disk(self):
        """摘要必须**以磁盘为准**：进程被强杀时只能靠明细文件反推。

        实测（2026-09-13 f3d）：合并进度文件后 digest 出现"事件 250 条但被拒原因空白、
        最后一轮世界缺失"——因为计数来自进度文件、榜单来自没人写的内存。
        反推之后三处数字必须一致（谁最后写都无所谓）。
        """
        self.archive.event({"kind": "damage", "server_tick": 100})
        self.archive.event({"kind": "arrival", "server_tick": 100})
        self.archive.command({"server_tick": 100, "action": "attack", "status": "Rejected",
                              "reason": "WeaponCannotTargetDomain"})
        self.archive.command({"server_tick": 100, "action": "move", "status": "Accepted"})
        self.archive.round_({"server_tick": 100, "units": [{"n": "Unit_1"}], "balance": 900})
        self.archive.round_({"server_tick": 160, "units": [{"n": "Unit_2"}], "balance": 800})
        self.archive.decision({"kind": "movement_gate", "server_tick": 160})
        self.archive.flush()
        report = self.archive.rebuild_from_files()
        self.assertTrue(report["rebuilt"])
        payload = self.archive.close(status="stopped")
        self.assertEqual(payload["counts"]["events"], 2)
        self.assertEqual(payload["counts"]["commands"], 2)
        self.assertEqual(payload["commands_by_status"], {"Rejected": 1, "Accepted": 1})
        self.assertEqual(list(payload["reject_reasons"]), ["WeaponCannotTargetDomain"])
        self.assertEqual(payload["first_tick"], 100)
        self.assertEqual(payload["last_tick"], 160)
        text = self.archive.digest(payload)
        self.assertIn("WeaponCannotTargetDomain", text)
        self.assertIn("Accepted", text)
        self.assertIn("我方单位：1", text, "最后一轮世界必须来自磁盘上最后一行")

    def test_compact_helpers_shrink_payload(self):
        raw_unit = {"name": "Unit_1", "unit_type": "soldier", "pos": [10.0, 0.0, 7.0],
                    "hp": 88.0, "script": "res://very/long/path.gd", "barrel": 1.57,
                    "task": {"deep": {"nested": True}}}
        compact = ma.compact_units([raw_unit])[0]
        self.assertEqual(compact["p"], [10.0, 7.0])
        self.assertNotIn("script", compact)
        self.assertNotIn("task", compact)
        self.assertEqual(compact["hp"], 88.0)
        enemy = ma.compact_enemies([{"name": "Unit_5", "unit_type": "tank",
                                    "pos": [40.0, 0.0, 40.0], "hp": 100.0,
                                    "last_seen_tick": 600}])[0]
        self.assertEqual(enemy["seen"], 600)
        production = ma.compact_production([{"producer": "Unit_0", "items": [
            {"item_id": "soldier", "state": "running", "completed_work": 3,
             "required_work": 10}]}])[0]
        self.assertEqual(production["queue"], 1)
        self.assertEqual(production["work"], "3/10")
        # 10Hz 快照用 `unit` 当生产者字段名（两套都要认，否则摘要里生产设施全空白）。
        snapshot_style = ma.compact_production([{"unit": "Unit_0", "queue_size": 2,
                                                "items": [{"item_id": "worker"}]}])[0]
        self.assertEqual(snapshot_style["producer"], "Unit_0")
        self.assertEqual(snapshot_style["queue"], 2)


if __name__ == "__main__":
    unittest.main()
