# -*- coding: utf-8 -*-
"""临时补丁：按 D1/D2 新合同更新四项测试。"""

PATH = "tests/test_task_loop.py"

text = open(PATH, encoding="utf-8").read()

# 1) 冷却保持：需要"已下发且被拒绝"的尝试才走到冷却检查
old1 = '''        tl.diagnose(record, facts=make_facts(), state=state, tick=100, mono=1.0)
        # C2 返修：刚授权、还没有任何回执 → 先等待本次尝试的结果
        # （未调度/在途不计失败），保持当前流程态。
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=100, mono=1.0)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "awaiting_attempt_result")
        # 结果回来（尝试已结论）且冷却未到 → 冷却保持。
        record["attempt_result_tick"] = 150
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "cooldown_active")'''

new1 = '''        tl.diagnose(record, facts=make_facts(), state=state, tick=100, mono=1.0)
        # 刚授权、还没有任何下发 → 等待本次尝试被调度（不计失败）。
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=100, mono=1.0)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "awaiting_attempt_result")
        # 本次尝试的命令已下发且被**拒绝**（按身份结算）→ 尝试结论；
        # 冷却未到 → 冷却保持（RECOVERING 不翻 DIAGNOSING）。
        record["attempt_intents"] = ["i-attempt-1"]
        record["attempt_receipts"] = [{"key": "i-attempt-1|c1", "intent_id": "i-attempt-1",
                                       "command_id": "c1", "status": "Rejected",
                                       "accepted": False, "tick": 150}]
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        self.assertEqual(record["retries_used"], 1)
        self.assertEqual(record["attempt_fail_kind"], "execution_failed")
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "cooldown_active")'''

assert old1 in text, "pattern 1 not found"
text = text.replace(old1, new1)

# 2) 回执关联：attempt_started 早于意图 issued_tick 才归属本次尝试
old2 = '''        state = make_state(server_tick=200, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"], "target": {"scene": "res://x/ore_refinery.tscn"},
            "issued_tick": 100, "expires_tick": 100000}]
        state["command_receipts"] = [
            {"intent_id": "i-1", "status": "Rejected", "server_tick": 150}]
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t"]
        tl.evaluate(state, tick=200, facts=make_facts())
        self.assertEqual(record["attempt_result_tick"], 150)'''

new2 = '''        state = make_state(server_tick=200, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"], "target": {"scene": "res://x/ore_refinery.tscn"},
            "issued_tick": 100, "expires_tick": 100000}]
        state["command_receipts"] = [
            {"intent_id": "i-1", "command_id": "c1", "status": "Rejected",
             "accepted": False, "server_tick": 150}]
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t"]
        # 授权早于意图 issued_tick → 该意图属于本次尝试，回执按身份结算。
        record["attempt_started_tick"] = 90
        record["attempt_counted_tick"] = -1
        tl.evaluate(state, tick=200, facts=make_facts())
        self.assertEqual(record["attempt_result_tick"], 150)
        self.assertEqual([i["intent_id"] for i in record["attempt_receipts"]], ["i-1"])
        # 旧命令（授权前 issued）不归属本次尝试：不结算、不结论。
        state["command_receipts"] = [
            {"intent_id": "i-old", "command_id": "c0", "status": "Rejected",
             "accepted": False, "server_tick": 95}]
        state["active_intents"].append({
            "intent_id": "i-old", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"], "target": {"scene": "res://x/ore_refinery.tscn"},
            "issued_tick": 50, "expires_tick": 100000})
        record["attempt_started_tick"] = 90
        record["attempt_counted_tick"] = -1
        record["attempt_receipts"] = []
        tl.evaluate(state, tick=200, facts=make_facts())
        self.assertEqual(record["attempt_receipts"], [],
                         "授权前的旧命令回执不得结算新尝试")'''

assert old2 in text, "pattern 2 not found"
text = text.replace(old2, new2)

# 3) 零执行：走调度等待预算，不计执行失败
old3 = '''        # 窗口过后才结论并进入下一次授权；第 3 次也要等自己的窗口才 blocked。
        self.assertEqual(seen[-1][1], "blocked")
        self.assertEqual(seen[-1][3], tl.DEFAULT_RETRY_BUDGET)
        self.assertGreaterEqual(seen[-1][0], 190, "最后一次尝试必须等到自己的窗口")
        # 三次授权全部发生，且每次都等到了自己的窗口（130/160/190 = 100+30k）。
        self.assertEqual([row[2] for row in seen if row[2]], [1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3])'''

new3 = '''        # D1/语义边界返修：零下发走**调度等待预算**，不计执行失败。
        # 第 3 次也要等自己的窗口才 blocked；retries_used 始终为 0。
        self.assertEqual(seen[-1][1], "blocked")
        self.assertEqual(seen[-1][3], 0, "零执行不得记为执行失败")
        self.assertEqual(record["schedule_waits"], tl.DEFAULT_RETRY_BUDGET)
        self.assertEqual(record["attempt_fail_kind"], "no_dispatch")
        self.assertGreaterEqual(seen[-1][0], 190, "最后一次尝试必须等到自己的窗口")
        # 三次授权全部发生，且每次都等到了自己的窗口（130/160/190 = 100+30k）。
        self.assertEqual([row[2] for row in seen if row[2]], [1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3])'''

assert old3 in text, "pattern 3 not found"
text = text.replace(old3, new3)

# 4) 结果结论：区分拒绝（计预算）与接受（在途不计）
old4 = '''        state = make_state(server_tick=100, active_tasks={"t": "running"})
        record = tl.new_record("t", kind="build", tick=100)
        record["building_type"] = "ore_refinery"
        record["state"] = tl.TASK_RECOVERING
        record["attempt"] = 1
        record["attempt_started_tick"] = 100
        record["attempt_counted_tick"] = -1
        record["attempt_result_tick"] = 150     # 回执已到（tick 150）
        state["task_ledger"] = {"t": record}
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        # 第 1 次尝试已结论（retries 0→1），并当场授权第 2 次（attempt 1→2）；
        # 新尝试的 counted 重置为 -1（它的结论还没发生）。
        self.assertEqual(record["retries_used"], 1)
        self.assertEqual(record["attempt"], 2)
        self.assertEqual(record["attempt_counted_tick"], -1)
        self.assertEqual(code, "recovery_attempt")
        self.assertIn("已结论 1/3", cn)'''

new4 = '''        def _attempt_with_receipt(accepted):
            state = make_state(server_tick=100, active_tasks={"t": "running"})
            record = tl.new_record("t", kind="build", tick=100)
            record["building_type"] = "ore_refinery"
            record["state"] = tl.TASK_RECOVERING
            record["attempt"] = 1
            record["attempt_started_tick"] = 100
            record["attempt_counted_tick"] = -1
            record["attempt_intents"] = ["i-1"]
            record["attempt_receipts"] = [{
                "key": "i-1|c1", "intent_id": "i-1", "command_id": "c1",
                "status": "Accepted" if accepted else "Rejected",
                "accepted": accepted, "tick": 150}]
            state["task_ledger"] = {"t": record}
            return state, record

        # D1：**拒绝**回执 → 尝试结论，计入执行预算并授权下一次。
        state, record = _attempt_with_receipt(False)
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        self.assertEqual(record["retries_used"], 1)
        self.assertEqual(record["attempt_fail_kind"], "execution_failed")
        self.assertEqual(record["attempt"], 2)
        self.assertEqual(code, "recovery_attempt")
        self.assertIn("已结论 1/3", cn)

        # D1：**接受**回执 → 正常在途，不消耗预算（生产/建造需要时间）。
        state, record = _attempt_with_receipt(True)
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "attempt_in_flight")
        self.assertEqual(record["retries_used"], 0)
        self.assertEqual(record["attempt_counted_tick"], -1)'''

assert old4 in text, "pattern 4 not found"
text = text.replace(old4, new4)

open(PATH, "w", encoding="utf-8").write(text)
print("tests updated for D1/D2 contract")
