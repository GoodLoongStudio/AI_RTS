# -*- coding: utf-8 -*-
"""查重：先按大小分组，再对同大小的文件算完整 sha1，找出完全相同的文件。

只报告不动手。输出：可去重释放的空间（保留每组的第一个副本）。
"""
import hashlib
import os
import sys
from collections import defaultdict


def sha1_of(path, chunk=1 << 20):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def dup_scan(root, min_size=64 * 1024):
    by_size = defaultdict(list)
    total = 0
    n = 0
    for dirpath, dirnames, filenames in os.walk(root):
        for f in filenames:
            p = os.path.join(dirpath, f)
            try:
                s = os.path.getsize(p)
            except OSError:
                continue
            total += s
            n += 1
            if s >= min_size:
                by_size[s].append(p)

    hash_groups = defaultdict(list)
    hashed_bytes = 0
    for size, paths in by_size.items():
        if len(paths) < 2:
            continue
        for p in paths:
            try:
                hash_groups[(size, sha1_of(p))].append(p)
                hashed_bytes += size
            except OSError:
                pass

    dups = {k: v for k, v in hash_groups.items() if len(v) > 1}
    reclaim = sum(k[0] * (len(v) - 1) for k, v in dups.items())
    print(f"\n=== 查重 {root} ===")
    print(f"扫描 {n} 个文件 / {total/1048576:.0f} MB（对 {hashed_bytes/1048576:.0f} MB 做了哈希）")
    print(f"重复组 {len(dups)}，可释放 {reclaim/1048576:.1f} MB")
    print("--- 最大的 10 组 ---")
    for (size, _), paths in sorted(dups.items(), key=lambda x: -x[0][0] * (len(x[1]) - 1))[:10]:
        print(f"  {size*(len(paths)-1)/1048576:8.1f} MB × {len(paths)} 份  {size/1048576:.1f} MB/份")
        for p in paths[:3]:
            print(f"        {os.path.relpath(p, root)}")
    return reclaim


if __name__ == "__main__":
    dup_scan(sys.argv[1])
