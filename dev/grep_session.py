# -*- coding: utf-8 -*-
"""在副官会话日志里搜建筑/摧毁相关记录（只读诊断）。"""
import json
import sys

path = sys.argv[1]
keys = ['建筑', '摧毁', 'destroy', 'died', '死亡', '残留', 'ghost', '残影', '敌方', 'enemy', 'turret', 'barracks', 'refinery']
hits = {k: 0 for k in keys}
samples = {}
for line in open(path, encoding='utf-8'):
    low = line.lower()
    for k in keys:
        if k.lower() in low:
            hits[k] += 1
            samples.setdefault(k, line.strip()[:600])
print('=== 关键词命中 ===')
for k, v in hits.items():
    print(v, k)
print('=== 样本 ===')
for k in keys:
    if k in samples:
        print('---', k, ':', samples[k])
