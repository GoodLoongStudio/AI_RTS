# 简单 AI 少造重型 + 副官防御塔外围选址 Implementation Plan

## Overview
简单档规则 AI 不再用坦克填满编制；副官（地板阶梯 + 模型落点）把防御塔放到当前己方视野能覆盖的最外圈，而不是套在指挥中心旁边。

## Current State Analysis
- 简单档关掉步兵、主产仍是坦克，2×4 编制会堆出一队重型。
- 副官建造落点只有基地 4/6/8m 环，且同等净空时优先更近半径；模型 BLD 也不猜坐标，塔和兵营共用这套内圈点。
- 权威端只接受视野内落点（约 8m），所以外围必须沿已有建筑/单位把环外推，而不能凭空放到 20m 外。

## Implementation Strategy
1. 简单档：保留车厂，重型（坦克/直升机）上限 1，步兵补满编制，不开机场副线。
2. `placement` 增加沿方位走到最远合法点的外围候选；地板 `pick_turret_spot`、模型 `turret_spots` 共用。
3. 塔的打分：离基地远、与已有塔错开、朝敌/地图中心、避开采矿道；仍过 `spot_issue`。

## Implementation Steps
1. 本计划
2. 简单档出兵权重
3. 外围候选与副官选址
4. 单测钉住“塔比内圈远、仍在视野内”

## Timeline
本轮改规则与副官落点，不改地形/大厅。

## Risk Assessment
- 开局只有基地时，最外圈仍约 8m（视野硬顶）；基地长大后才会真正外推。
- 规则 AI 的 PlaceStructure 仍可能拒掉超视野点，外圈失败则回退内圈。

## Success Criteria
- 简单档场上坦克/直升机不超过 1，其余编制是步兵
- 有外围建筑时，副官第一座塔距指挥中心 ≥ 8m
- 落点仍过 `placement.spot_issue`（不刷 NotVisible）

## Progress Tracking
- ✅ 计划
- ✅ 简单档出兵
- ✅ 副官外围塔
- ✅ 单测

## Related Files
- `source/match/players/simple-clairvoyant-ai/OffenseController.gd`
- `source/match/players/simple-clairvoyant-ai/DefenseController.gd`
- `source/adjutant_coordinator/graph/placement.py`
- `source/adjutant_coordinator/graph/rules_fallback.py`
- `source/adjutant_coordinator/graph/squads.py`
- `source/adjutant_coordinator/graph/task_patch.py`
- `source/adjutant_coordinator/tests/test_development_ladder.py`
- `source/adjutant_coordinator/tests/test_task_patch.py`
