# -*- coding: utf-8 -*-
"""磁盘审计：按目录/扩展名统计真实字节数（不用 du，du 在本机虚高）。"""
import os
import sys
from collections import defaultdict

SKIP_DIRS = {".git"}


def walk_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            p = os.path.join(dirpath, f)
            try:
                yield p, os.path.getsize(p)
            except OSError:
                pass


def scan(root, top_dirs=8, top_ext=8):
    ext_sum = defaultdict(int)
    ext_cnt = defaultdict(int)
    child_sum = defaultdict(int)
    total = 0
    n = 0
    for p, s in walk_files(root):
        total += s
        n += 1
        ext = os.path.splitext(p)[1].lower() or "(无扩展名)"
        ext_sum[ext] += s
        ext_cnt[ext] += 1
        rel = os.path.relpath(p, root)
        top = rel.split(os.sep)[0]
        child_sum[top] += s
    print(f"\n=== {root} ===")
    print(f"总计 {total/1048576:.0f} MB / {n} 个文件")
    print("--- 按一级目录 ---")
    for k, v in sorted(child_sum.items(), key=lambda x: -x[1])[:top_dirs]:
        print(f"  {v/1048576:9.1f} MB  {k}")
    print("--- 按扩展名 ---")
    for k, v in sorted(ext_sum.items(), key=lambda x: -x[1])[:top_ext]:
        print(f"  {v/1048576:9.1f} MB  {ext_cnt[k]:6d} 个  {k}")


if __name__ == "__main__":
    for target in sys.argv[1:]:
        scan(target)
