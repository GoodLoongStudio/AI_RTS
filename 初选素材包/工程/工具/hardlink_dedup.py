# -*- coding: utf-8 -*-
"""把完全相同的重复文件替换为 NTFS 硬链接。

不同于删除：目录结构、文件名、逻辑大小全部不变，任何工具（fbx 找配套纹理、
Godot .import 配置）都照常工作，磁盘只存一份物理数据。可逆：删掉链接、复制回
独立文件即可恢复。

安全写法：先建 <目标>.__link_tmp__，再 os.replace 原子替换，
中途失败不会丢文件。
"""
import hashlib
import os
import sys
from collections import defaultdict

MIN_SIZE = 64 * 1024


def sha1_of(path, chunk=1 << 20):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def collect(root):
    by_size = defaultdict(list)
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            p = os.path.join(dirpath, f)
            try:
                s = os.path.getsize(p)
            except OSError:
                continue
            if s >= MIN_SIZE:
                by_size[s].append(p)

    groups = defaultdict(list)
    for size, paths in by_size.items():
        if len(paths) < 2:
            continue
        for p in paths:
            try:
                groups[(size, sha1_of(p))].append(p)
            except OSError:
                pass
    return {k: v for k, v in groups.items() if len(v) > 1}


def link_duplicates(root, apply: bool = False):
    groups = collect(root)
    freed = 0
    linked = 0
    failed = 0
    for (size, _), paths in sorted(groups.items(), key=lambda x: -x[0][0]):
        keep = sorted(paths)[0]
        for dup in sorted(paths)[1:]:
            if os.path.samefile(keep, dup):
                continue
            freed += size
            if not apply:
                linked += 1
                continue
            tmp = dup + ".__link_tmp__"
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
                os.link(keep, tmp)
                os.replace(tmp, dup)
                linked += 1
            except OSError as e:
                failed += 1
                if os.path.exists(tmp):
                    try:
                        os.remove(tmp)
                    except OSError:
                        pass
                print(f"  !! 失败 {dup}: {e}")
    return len(groups), linked, failed, freed


if __name__ == "__main__":
    root = sys.argv[1]
    apply = "--apply" in sys.argv
    g, linked, failed, freed = link_duplicates(root, apply=apply)
    mode = "已执行" if apply else "预演"
    print(f"{mode}: {g} 组重复，{linked} 个文件转为硬链接，失败 {failed}，"
          f"可释放 {freed/1048576:.1f} MB")
