# 基地袭击召回回防 Implementation Plan

## Overview
副官在敌方进攻时不回防。真机从不发 `base_under_attack`，前线集结又把作战单位送出回防圈，家里没人就不会召回。本轮让受袭从事实合成，并在家里没兵时召回最近的少量作战单位。

## Current State Analysis
- 游戏端 `DebugControlServer` 只报 `damage` / `unit_lost`，从不报 `base_under_attack`。
- 决策地图 D10、行为树回防、并行填充都只认中断栈里的 `base_under_attack`。
- 手册 DEF-01 写了「事件或基地附近见敌」，代码故意不用见敌，避免路上偶遇变成全军回防。
- 回防还要求单位已经在 `DEFENSE_RADIUS_M=40` 内。前压/前线集结之后圈内经常是空的，远处线按 T07 继续前压。
- 劣势撤离排在回防前面：家里被打时，唯一的兵会往脱离点跑，而不是回家。

## Implementation Strategy
1. 用「己方建筑附近见敌」或「己方建筑掉血」合成 `base_under_attack`。路上见敌不合成。
2. 家里回防圈已有足够作战单位时，远处线仍不召回（保留 T07）。
3. 家里没人（或不够配额）时，按距基地从近到远召回，最多 3 个，不是全军。
4. 回防优先于野外劣势撤离，避免弃家逃跑。

## Implementation Steps
1. 本计划
2. `campaign.update` 合成受袭；`facts.home_points` 供解除判定
3. `home_raid_visible` / `defense_recall_names`；行为树与并行填充共用
4. 手册 DEF-01 与守门测试

## Timeline
本轮一次改完合成与召回，不另开「再攒一版」。

## Risk Assessment
- 把野外交战误判成基地受袭：只认建筑附近半径，不认任意可见敌人。
- 召回过大变成全军回防：配额上限 3，家里够人就不召。
- 旧 T07 断言「1 近 1 远也不召」：改为「圈内已满配额则远处不召」。

## Success Criteria
- 基地 40 米内出现可见敌人、且没有 `base_under_attack` 事件，中断栈仍会亮、D10 可选
- 指挥中心掉血、视野里没有敌人，也会压受袭中断
- 野外交战（敌人远离己方建筑）不合成受袭
- 家里没有作战单位时，最近的野外作战单位收到 `defend`
- 家里已有 3 个作战单位时，远处线不 `defend`、不打家里的敌人

## Progress Tracking
- ✅ 计划
- ✅ 合成受袭
- ✅ 召回执行
- ✅ 测试

## Related Files
- `source/adjutant_coordinator/graph/campaign.py`
- `source/adjutant_coordinator/graph/rules_fallback.py`
- `source/adjutant_coordinator/graph/behavior_tree.py`
- `docs/策划文档/AI副官决策手册/05-策略库-军事与作战.md`
- `source/adjutant_coordinator/tests/test_campaign_mainline.py`
- `source/adjutant_coordinator/tests/test_behavior_tree.py`
