# 步兵登车与浮空 Implementation Plan

## Overview
单机生成图上步兵右键进不了运输车，步兵和装甲车明显离开沙面。按截图：点地没有登车令，单位原点/模型也没贴在看见的沙面上。

## Current State Analysis
- 登车只走 `unit_targeted`。大图关掉地形碰撞后，右键常打到 Y=0 平面，点中视觉车身也进不了 `CargoHold.mark_boarding`。
- 跟上车后用三维距离 3m 判定；高度不一致时贴着车也不装载。
- 运输车碰撞只有半径 0.8、高 0.6，模型还有 Y=0.25 悬停偏移，更难点中。
- `_plant_feet_on_origin` 没有留在驱动里；载具只在入树时种一次视觉，网格未就绪就不再贴。
- 建筑网格原点在中部，埋进沙里所以看起来贴地；步兵/载具原点在脚底/底盘，高出沙面一眼能看出来。

## Implementation Strategy
右键点地若靠近己方运输车，按登车处理，并直接下达走到车旁。装载改平面距离。每帧按脚骨/网格最低点把视觉落到单位原点，并去掉运输车悬停抬高。

## Implementation Steps
1. 本计划
2. 登车：点地兜底、直接移动、平面装载、加大点选
3. 浮空：步兵脚骨与载具 AABB 每帧贴地

## Timeline
本轮完成。

## Risk Assessment
- 点地登车半径过大时，想走到车旁会被当成上车；半径取 4m，且必须已选中可装载地面单位。
- 跑步时每帧钉脚会抖，只在站定时钉脚骨。

## Success Criteria
- 选中步兵，右键运输车或车旁沙地，走到附近即上车
- 步兵脚底、运输车底盘贴沙，不再悬在圈上方

## Progress Tracking
- ✅ 计划
- ✅ 登车
- ✅ 贴地

## Related Files
- `source/match/players/human/UnitActionsController.gd`
- `source/match/units/traits/CargoHold.gd`
- `source/match/units/traits/Movement.gd`
- `source/match/units/InfantryAnimationDriver.gd`
- `source/match/units/TransportTruck.tscn`
