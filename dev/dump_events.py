# -*- coding: utf-8 -*-
"""汇总副官会话事件类型（只读诊断）。"""
import json
import collections
import sys

p = sys.argv[1]
c = collections.Counter()
samples = {}
bad = 0
for line in open(p, encoding='utf-8'):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        bad += 1
        continue
    key = d.get('event') or d.get('type') or 'unknown'
    c[key] += 1
    samples.setdefault(key, line[:400])
print('parse-fail:', bad)
for k, v in c.most_common(40):
    print(v, k)
print('=== samples ===')
for k in list(samples)[:15]:
    print('---', k, ':', samples[k])
