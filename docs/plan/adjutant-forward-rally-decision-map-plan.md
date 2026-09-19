# 副官决策地图前线集结 Implementation Plan

## Overview
校验并改写副官军事决策地图：空闲集结、前压、撤退、重组都不再默认回主基地。主基地只留给基地受袭回防。

## Current State Analysis
决策地图 D11「集结（不添油）」候选目标是 `anchor`（主基地），前置是「有兵但未达集结规模」。一个作战单位时，模型看到的军事选项就是回家。D13/D14 同样指向 `anchor`。手册 ATK-01 仍写「集结点建议在基地附近」。

运行时比决策地图更硬：行为树 `_regroup` 写死 `home_anchor`；守家名额按名字拉最多 3 个野外单位回主基地；前压航点以主基地为圆心 15–40 米；撤退坐标等于主基地；受阻降级没有小队中继点时也回主基地；引用表 L1 叫「基地」且坐标就是指挥中心。

用户口径（2026-09-14）：副官可以高频操作，没必要在主基地攒大军，小部队快速集结后就该行动。主基地门口集结没有占图、施压、接敌价值。

## Implementation Strategy
1. 决策地图：D11 改为前线快集结（目标 `location`，仅队形散开时可选）；新增 D15 前压；D12 有敌情即可选，不再卡「先回家攒够人数」；D13/D14 改指向脱离点/前线点。
2. 选点唯一口径：`forward_rally_point` / `disengage_point`。前线点来自敌情、小队中心或地图中心，禁止落在主基地上。
3. 行为树：野外单位前压或集结到前线点；已在基地圈内的单位原地警戒；撤退走脱离点。
4. 引用表 L1 改为前线集结点；受阻降级回前线/脱离点，不再默认主基地。

## Implementation Steps
1. 本计划
2. 手册 01/05 与 `decision_map.py`
3. `rules_fallback` 选点函数 + `campaign` 事实 `units_scattered`
4. 行为树、`frontier_preferences`、`squads` 引用表、`nodes` 受阻降级
5. 守门测试

## Timeline
本轮一次改完决策地图与执行层，不另开「再攒一版」。

## Risk Assessment
- 单兵无情报时若仍围着家转：前压改为始终按搜索半径朝地图中心/情报走。
- 撤退若仍踩进主基地：脱离点必须把落点从指挥中心推开。
- 旧测试把「回主基地」当成正确行为：按新口径改断言。

## Success Criteria
- D11/D13/D14 候选不再以主基地 `anchor` 为集结/撤退目标
- 野外空闲作战单位不出现「regroup 到主基地坐标」
- 散开小队的集结点与主基地距离 ≥ 12 米
- 已有守门测试通过

## Progress Tracking
- ✅ 计划
- ✅ 决策地图与手册
- ✅ 前线/脱离选点
- ✅ 行为树与引用表
- ✅ 测试

## 迭代记录
- 散开判定若把家里的兵算进去，前线点会被拽回主基地附近。现只看野外作战单位。
- 前压航点若以指挥中心为原点，效果仍是围着家转圈。现从单位自己的位置往外推。
- 脱离点贴边夹紧后再推离主基地，可能被翻到敌人方向。现改试垂直方向，落点必须更远离敌人。

## Related Files
- `source/adjutant_coordinator/graph/decision_map.py`
- `source/adjutant_coordinator/graph/rules_fallback.py`
- `source/adjutant_coordinator/graph/behavior_tree.py`
- `source/adjutant_coordinator/graph/campaign.py`
- `source/adjutant_coordinator/graph/squads.py`
- `source/adjutant_coordinator/graph/nodes.py`
- `docs/策划文档/AI副官决策手册/01-总则与决策地图.md`
- `docs/策划文档/AI副官决策手册/05-策略库-军事与作战.md`
- `source/adjutant_coordinator/tests/test_behavior_tree.py`
- `source/adjutant_coordinator/tests/test_campaign_mainline.py`
- `source/adjutant_coordinator/tests/test_forward_rally.py`
