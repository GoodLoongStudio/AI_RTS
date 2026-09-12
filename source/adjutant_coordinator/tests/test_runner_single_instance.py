# -*- coding: utf-8 -*-
"""一局一个 runner：一对一锁的回归守卫。

用户 2026-09-12 晚指出："现在对局会出现 1 个对局启动多个 runner，这个不一对一会让
你检测的时候出问题吧？" —— 会。两个 runner 同时指挥同一局会：
① 对同一批单位下发**互相冲突**的命令；
② 在单并发的本地模型上互相排队（实测把"一次思考"从 0.7 秒拖到 **4.7 秒**，
   当时的节拍测量就是被这个污染的）。

这里只测锁本身（不连对局）：同键第二次必须被拒、陈旧锁必须能接管、
不同对局（不同权威端口）不许互相排斥。
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.deploy.agent_runner import AgentRunner, build_parser  # noqa: E402


def make_runner(log_dir, port="24572", player="Player_0"):
    args = build_parser().parse_args([
        "--authority-port", str(port), "--player", player, "--log-dir", log_dir,
        "--state-dir", log_dir, "--pidfile", os.path.join(log_dir, "runner.pid"),
        "--model", "off", "--strategy-mode", "off", "--allow-other-port",
    ])
    return AgentRunner(args)


class SingleInstanceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="adjutant_lock_")

    def test_second_runner_on_same_match_is_rejected(self):
        first = make_runner(self.tmp)
        self.assertEqual(first._acquire_single_instance(), 0)
        try:
            occupant = make_runner(self.tmp)._acquire_single_instance()
            self.assertEqual(occupant, os.getpid(),
                             "同一 (authority_port, player) 的第二个 runner 必须被拒")
        finally:
            first._release_single_instance()

    def test_lock_released_allows_new_runner(self):
        first = make_runner(self.tmp)
        first._acquire_single_instance()
        first._release_single_instance()
        again = make_runner(self.tmp)
        self.assertEqual(again._acquire_single_instance(), 0)
        again._release_single_instance()

    def test_stale_lock_is_taken_over(self):
        path = make_runner(self.tmp)._single_instance_file()
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("999999")            # 不可能存在的 pid
        runner = make_runner(self.tmp)
        self.assertEqual(runner._acquire_single_instance(), 0,
                         "陈旧锁（进程已死）必须被接管，不能把下一次启动锁死")
        runner._release_single_instance()

    def test_different_match_does_not_collide(self):
        first = make_runner(self.tmp, port="24572")
        self.assertEqual(first._acquire_single_instance(), 0)
        second = make_runner(self.tmp, port="24582")
        try:
            self.assertEqual(second._acquire_single_instance(), 0,
                             "不同权威端口（不同对局）不应互相排斥")
        finally:
            first._release_single_instance()
            second._release_single_instance()


if __name__ == "__main__":
    unittest.main()
