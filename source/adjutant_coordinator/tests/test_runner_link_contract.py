# -*- coding: utf-8 -*-
"""副官链路契约测试：**不许把验收通道自己搞坏**。

## 为什么要有这个文件（用户 2026-09-12 晚的明确要求）

> "你们改的时候注意，不要把 AI 副官链路搞坏了，那你们还怎么测？"

副官（runner）链路**本身就是验收通道**：HUD 面板、心跳状态、事件 jsonl、回执统计
全都要靠它。它一断，我们既看不到现象也拿不到证据 —— 改造落点/账本这类"副官内部"
的改动，最容易顺手把它踩坏（例如把单实例锁写成 pidfile、把 pidfile 内容换成 JSON）。

契约（`source/ui/AdjutantButton.gd` 是读取方，改它属游戏侧，不归我们）：

| 文件 | 位置 | 内容 | 谁读 |
|---|---|---|---|
| `agent_runner.pid` | `--log-dir`（= `%APPDATA%\\Godot\\app_userdata\\Open RTS\\adjutant_logs`） | **纯十进制 PID**（`str(os.getpid())`） | HUD「认领握手」：内容合法即认领 |
| `hud_status.json` | 同上 | 面板四行（状态/最近行动/为什么/结果） | HUD 面板正文 |
| `agent_runner_events_*.jsonl` | 同上 | 结构化事件（receipt / intent_dropped / rule_floor…） | 验收分析器 |
| `agent_runner_<port>_<player>.lock` | 同上 | 单实例锁（**不是 pidfile**） | runner 自己 |

**最危险的破坏方式**：让单实例锁与 pidfile 共用一个路径（或把锁写进 pidfile），
HUD 立刻显示"没有运行中的 runner（pidfile 缺失或内容非法）"——看起来像副官坏了。
"""

import os
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.deploy import agent_runner as ar  # noqa: E402


def _runner(log_dir, pidfile, port=24572, player="Player_0"):
    """构造一个**不启动对局**的 AgentRunner 外壳（只测契约相关的写文件行为）。"""
    runner = ar.AgentRunner.__new__(ar.AgentRunner)
    runner.args = types.SimpleNamespace(log_dir=log_dir, pidfile=pidfile)
    runner.port = int(port)
    runner.player = str(player)
    runner._log = lambda *args, **kwargs: None      # 不写事件日志
    return runner


class PidfileContractTest(unittest.TestCase):
    """pidfile 的路径与内容必须与 HUD 的认领握手一致。"""

    def test_pidfile_content_is_plain_decimal_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "agent_runner.pid")
            runner = _runner(tmp, path)
            runner._write_pidfile()
            with open(path, encoding="utf-8") as handle:
                content = handle.read()
            self.assertEqual(content, str(os.getpid()),
                             "pidfile 必须是纯十进制 PID（HUD 直接 int() 解析）：%r" % content)
            self.assertTrue(content.strip().isdigit(), "不允许 JSON/多字段：%r" % content)

    def test_remove_pidfile_is_tolerant(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "agent_runner.pid")
            runner = _runner(tmp, path)
            runner._write_pidfile()
            runner._remove_pidfile()
            self.assertFalse(os.path.exists(path), "退出必须清掉 pidfile（否则 HUD 认领僵尸）")
            runner._remove_pidfile()      # 再删一次不得抛异常

    def test_pidfile_missing_is_skipped_without_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner = _runner(tmp, "")     # 未配置 pidfile（云端外的本地调试也可能）
            runner._write_pidfile()       # 不得抛异常
            self.assertEqual(os.listdir(tmp), [])


class SingleInstanceLockTest(unittest.TestCase):
    """单实例锁必须与 pidfile **分开**（这是"改坏链路"最容易犯的错）。"""

    def test_lock_is_a_separate_file_in_log_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = os.path.join(tmp, "agent_runner.pid")
            runner = _runner(tmp, pidfile)
            lock = runner._single_instance_file()
            self.assertEqual(os.path.dirname(lock), tmp, "锁必须在 --log-dir 内")
            self.assertNotEqual(lock, pidfile, "锁与 pidfile 必须是两个文件")
            self.assertNotEqual(os.path.basename(lock), "agent_runner.pid")
            self.assertIn(str(runner.port), os.path.basename(lock),
                          "锁要按局区分（端口进名字），不同局互不影响")
            self.assertTrue(os.path.basename(lock).endswith(".lock"))

    def test_acquire_and_release_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = os.path.join(tmp, "agent_runner.pid")
            runner = _runner(tmp, pidfile)
            self.assertEqual(runner._acquire_single_instance(), 0, "首次抢锁必须成功")
            lock = runner._single_instance_file()
            self.assertTrue(os.path.exists(lock))
            with open(lock, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), str(os.getpid()))
            # 自己还活着 → 第二个 runner 必须被拒（返回占用者 pid）。
            second = _runner(tmp, pidfile)
            self.assertEqual(second._acquire_single_instance(), os.getpid(),
                             "同一局不得有两个 runner（会下发互相冲突的命令）")
            runner._release_single_instance()
            self.assertFalse(os.path.exists(lock), "释放必须清锁，否则下次起不来")

    def test_stale_lock_is_taken_over(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner = _runner(tmp, os.path.join(tmp, "agent_runner.pid"))
            lock = runner._single_instance_file()
            with open(lock, "w", encoding="utf-8") as handle:
                handle.write("999999")     # 不存在的 pid = 陈旧锁
            self.assertEqual(runner._acquire_single_instance(), 0,
                             "陈旧锁必须能接管，不能把下一次启动锁死")


if __name__ == "__main__":
    unittest.main()
