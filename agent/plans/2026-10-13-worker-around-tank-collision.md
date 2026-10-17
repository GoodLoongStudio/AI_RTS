# 工人绕开建筑 + 坦克对坦克碰撞

## Overview
工人被已建成建筑挡住时要沿车身净空绕行并到达目标。坦克与坦克保持碰撞形状给出的平面间距，同时仍能移动和攻击。

## Current State Analysis
逻辑地形不烘焙导航网格，地面移动走 `GeneratedTerrain.find_ground_path`。A* 只把格子中心落在建筑多边形内的格子标成障碍，拉直又只测中心线是否穿过多边形。兵营案例里航点 (278, 226) 离墙 0.43 米，工人半径 1.251，推出停在约 1.20 米，停在 (276.41, 226.47)，距钳制目标 8.37 米。基线日志在 `agent/runs/20261013-worker-around-building/baseline-*.log`。

坦克根节点是 Area3D，物理层不挡单位。`Movement._resolve_ground_combat_step` 已有脚本侧硬碰撞，但没有对局证据。

## Implementation Strategy
寻路增加可选净空（单位 `Movement.radius`）：临时把代表点落在净空内的粗格标成障碍，线段按到多边形的距离判定，缓存键带上净空。`is_ground_blocked` / path_snap 仍用真实多边形。拐角上，捷径会擦进车身时先走到航点再转弯。

坦克先测现有硬碰撞。间距塌掉再改解析，不缩碰撞盒、不关避障、不改速度。

## Implementation Steps
- ✅ 定位兵营航点钻进推出距离
- ✅ `find_ground_path` 净空与工人请求半径
- ✅ 无头对局验收工人绕行
- ✅ 无头对局验收坦克间距（现有硬碰撞已生效，未改解析器）

## Timeline
同一轮改完并各开一局无头 Match。

## Risk Assessment
净空只加在寻路上，避免矿场落点被足迹外扩带偏。临时障碍必须在返回前恢复。坦克若半径没测到，先修识别，不改形状。

## Success Criteria
工人从 (260, 230) 到兵营 (280, 230)，结束点距钳制目标 ≤ 2 米，路径最近点到墙 ≥ 0.85 倍半径。两辆坦克相向开进，平面距离 ≥ 碰撞半径之和，且都移动超过 1 米。

## Progress Tracking
✅ 诊断  ✅ 代码  ✅ 验收

## Related Files
- `source/match/maps/generated/GeneratedTerrain.gd`
- `source/match/units/traits/Movement.gd`
- `tests/dev-probes/_WorkerAroundProbe.gd`
- `tests/dev-probes/_TankCollisionProbe.gd`
