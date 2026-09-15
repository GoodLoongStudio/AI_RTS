# G4 占用格绕行与脱位 Implementation Plan

## Overview
大图跳过 Recast 后，地面单位只沿直线走，`clamp_ground_move` 还把目标钳到河谷岸边并误判到达。本轮在占用格上做粗网格 A* 绕行，卡住时脱位，不允许部队停在水里或悬崖边。

## Current State Analysis
- `Movement._physics_process_logic_move` 直线朝 `_committed_target` 迈步。
- `GeneratedTerrain.clamp_ground_move` 用 `_last_land_along` 把对岸目标改成岸边。
- `clamp_ground_step` 挡住下一步后，逻辑移动直接 `Arrived`。
- 既有脱困状态机只挂在 NavigationServer 路径上，大图 `_skip_navigation_server` 时根本不跑。
- 禁行格已有水/岩掩码和桥面走廊（约 51 万格里 9 万禁行），缺高层寻路。

## Implementation Strategy
- 不恢复 513² Recast，不走高度图插件。
- 在 `GeneratedTerrain` 上：细格补陡崖禁行；4 细格合成约 2m 粗格；`AStarGrid2D` 寻路；桥面走廊按“可走比例”保留。
- 目标钳制改为 `clamp_ground_destination`：落点在水里才吸附到最近陆地，直线穿水不再改目标。
- `Movement` 跟随航点；水中/禁行格立刻脱位；迈步被挡则侧滑并重寻路；只有贴近任务目标才 `Arrived`。
- 每帧限制 A* 次数，按起终点粗格缓存路径。

## Implementation Steps
1. ✅ 写本计划
2. ✅ `GeneratedTerrain`：陡崖禁行、粗网格、`find_ground_path` / `unstick_ground`
3. ✅ `Movement`：航点跟随、脱位、禁止岸边假到达
4. ✅ `verify_g4_large_lake_playable` 增加跨湖绕行断言
5. ✅ headless 验证 + 活局工人过桥到达 P1

## Timeline
- 编码与 headless：本轮一次做完
- 活局过桥：同一轮用 DCS 复测

## Risk Assessment
- 粗格若按高度方差一刀切，会抹掉桥面 → 可走比例过半则保走廊
- 同帧 20 车同时 A* → 每帧 6 次预算 + 路径缓存
- 脱位叠车 → 按实例 id 偏置最近陆地

## Success Criteria
- P0 台地到 P1 平地的路径不穿湖，必经桥或坡
- 单位卡进河谷后会脱位并改道，不再 `Arrived` 在岸边
- 短距离空地移动仍直达
- 不打开 Recast，不打开物理分线程

## Progress Tracking
✅ 根因确认：直线 + 岸边钳制 + 假到达
✅ 占用格 A* 与脱位
✅ 验证脚本
✅ 活局过桥：工人偏航 18m，valley_hits=0，抵达 P1

## Related Files
- `source/match/maps/generated/GeneratedTerrain.gd`
- `source/match/units/traits/Movement.gd`
- `tools/verify_g4_large_lake_playable.gd`
