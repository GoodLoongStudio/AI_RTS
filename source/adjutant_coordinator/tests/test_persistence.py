# -*- coding: utf-8 -*-
"""持久化测试：目录隔离、原子写并发、单写入者锁、损坏容错。"""

import os
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.persistence import MatchPlayerStore, WriterLock


class TestIsolation(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="adj-coord-test-")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_match_player_directories_isolated(self):
        store_a = MatchPlayerStore(self.root, "match-1", "Player_1")
        store_b = MatchPlayerStore(self.root, "match-2", "Player_1")
        store_a.write_state("state", {"tick": 1})
        self.assertEqual(store_b.read_state("state"), None)
        self.assertNotEqual(store_a.directory, store_b.directory)

    def test_new_match_same_names_do_not_share_ledger(self):
        """新对局即使复用 Unit_1 等名称，旧账本也不会生效（目录隔离）。"""
        old_store = MatchPlayerStore(self.root, "match-old", "Player_1")
        old_store.write_state("lease", {"Unit_1": {"generation": 7, "active": True}})
        new_store = MatchPlayerStore(self.root, "match-new", "Player_1")
        self.assertEqual(new_store.read_state("lease"), None)


class TestAtomicWrite(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="adj-coord-test-")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_concurrent_writers_do_not_corrupt_state(self):
        """两个写入者并发写同一状态名：独立临时文件保证目标文件始终完整。"""
        store = MatchPlayerStore(self.root, "match-1", "Player_1")
        errors = []

        def writer(tag):
            try:
                for index in range(50):
                    store.write_state("state", {"writer": tag, "seq": index})
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)

        threads = [threading.Thread(target=writer, args=(tag,)) for tag in ("a", "b")]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        state = store.read_state("state")
        self.assertIsNotNone(state)
        self.assertIn("writer", state)

    def test_no_fixed_tmp_file_collisions(self):
        """临时文件名含 pid+uuid，不会固定 .tmp 互相覆盖。"""
        store = MatchPlayerStore(self.root, "match-1", "Player_1")
        store.write_state("s", {"x": 1})
        leftovers = [f for f in os.listdir(store.directory) if f.endswith(".tmp")]
        self.assertEqual(leftovers, [])


class TestWriterLock(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="adj-coord-test-")
        self.lock_path = os.path.join(self.root, "writer.lock")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_lock_is_exclusive(self):
        first = WriterLock(self.lock_path)
        second = WriterLock(self.lock_path)
        self.assertTrue(first.acquire())
        self.assertFalse(second.acquire())
        first.release()
        self.assertTrue(second.acquire())
        second.release()

    def test_stale_lock_recovered(self):
        """持有进程死亡后的陈旧锁可安全回收（pid 活性检测）。"""
        with open(self.lock_path, "w", encoding="utf-8") as handle:
            # 用一个几乎不可能存在的 pid（Windows/Linux 下 0/负数无效）。
            handle.write("999999999")
        lock = WriterLock(self.lock_path)
        self.assertTrue(lock.acquire())

    def test_corrupt_state_returns_default_not_crash(self):
        store = MatchPlayerStore(self.root, "match-1", "Player_1")
        target = os.path.join(store.directory, "broken.json")
        with open(target, "w", encoding="utf-8") as handle:
            handle.write("{not valid json")
        self.assertEqual(store.read_state("broken", default="fallback"), "fallback")


if __name__ == "__main__":
    unittest.main()
