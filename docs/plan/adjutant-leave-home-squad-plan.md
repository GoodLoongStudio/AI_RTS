# 副官小队出门 Implementation Plan

## Overview
副官不再把刚出厂的作战单位留在家里发呆。几个单位成小队就去探索、进攻；只有基地受袭才回防。

## Current State Analysis
新兵出生点在主基地圈内。微操树先把圈内最多 3 个作战单位标成守家并 `hold`，前压排在后面。结果是家里永远站着一堆人，野外没人探、没人打。

## Implementation Strategy
空闲时守家名单为空，圈内作战单位走前压探索。基地受袭仍由回防档召回少量最近单位。出击门槛保持小队规模（2）。

## Implementation Steps
1. 本计划
2. 空闲不守家，单测改成出门
3. 受袭回防保持

## Timeline
本轮完成。

## Risk Assessment
家里无人看守时，偷袭要靠召回。召回上限仍是 3，远处线不全部拉回。

## Success Criteria
- 无敌人时，家里的步兵/坦克拿到前压，不再 `hold`
- 建筑附近见敌时，圈内或召回名单走回防

## Progress Tracking
- ✅ 计划
- ✅ 改树与单测

## Related Files
- `source/adjutant_coordinator/graph/behavior_tree.py`
- `source/adjutant_coordinator/tests/test_behavior_tree.py`
