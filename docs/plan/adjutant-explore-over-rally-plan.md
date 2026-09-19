# 副官探索进攻优先于集合 Implementation Plan

## Overview
副官不要再把刚出门的部队拉回去集合。空闲时前压探索、见敌就打，集结只在关掉前压时兜底。

## Current State Analysis
微操树先判定 `units_scattered` 再发 `regroup`。部队按不同方位出门后被判散开，立刻拉到前线点，看起来就是在家门口集合。决策图 D11 集结优先级也高于早期进攻。

## Implementation Strategy
- 允许前压时不发集结
- 树顺序改为前压在集结前
- 空闲集结默认关闭
- 前压意图优先级提高到 45
- D12 进攻在立足/扩张阶段也可选；D11 优先级下调

## Implementation Steps
1. ✅ 写本计划
2. ✅ 改树与默认开关
3. ✅ 改决策图
4. ✅ 单测 46 通过

## Timeline
本轮一次做完。

## Risk Assessment
野外队形会散开。受袭回防仍走独立回防档。

## Success Criteria
- 默认配置下散开的空闲作战单位拿 `attack_move`，不拿 `regroup`
- 关掉前压后仍可显式打开集结
- 立足阶段有敌情可选进攻节点

## Progress Tracking
✅ 根因
✅ 代码与单测

## Related Files
- `source/adjutant_coordinator/graph/behavior_tree.py`
- `source/adjutant_coordinator/graph/decision_map.py`
- `source/adjutant_coordinator/tests/test_behavior_tree.py`
