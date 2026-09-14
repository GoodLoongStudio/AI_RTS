# 生成地图进局全黑 Implementation Plan

## Overview
2048m 生成图能加载进对局，但画面全黑，无法互动看坡道。根因是战争迷雾按 50m 小图做的黑遮罩，加上镜头远平面/高度仍按小图计算。

## Current State Analysis
- 日志已 `Match 就绪`，地图实例成功。
- `FogOfWar.resize(2048)` 会建 4096² 视口；遮罩 shader 在 UV 越界或深度解算失败时 `ALPHA=1` 整屏黑。
- 正交相机 `far` 只算到 `visible_height_min=-10`，约几十米；山体世界高约 207m。
- 自定义对局默认 `PER_PLAYER` 迷雾，不会走 FULL 的关遮罩分支。

## Implementation Strategy
大地图（边长 ≥ 256）进局时关掉战争迷雾遮罩，拉高镜头、加长 far，开局略拉远。迷雾视口加 1024 上限，避免再分配 4096²。

## Implementation Steps
1. `Match.gd`：大地图关 FoW + 配置相机
2. `IsometricCamera3D.gd`：far / 可见高度 / 开局缩放
3. `FogOfWar.gd`：视口边长封顶
4. 再开一局给用户转

## Timeline
单轮代码 → 开窗验证。

## Risk Assessment
- 大地图评图暂无迷雾，不影响 Plain & Simple
- 开局拉远后仍可用滚轮拉近

## Success Criteria
进局能看见沙地/台地/单位，方向键可平移，滚轮可缩放。

## Progress Tracking
- ✅ 计划
- ✅ 改 Match / 相机 / FoW
- ✅ 开局给用户看（fog_off，far=4288，size=90）

## Related Files
- `AI_RTS/source/match/Match.gd`
- `AI_RTS/source/match/IsometricCamera3D.gd`
- `AI_RTS/source/match/FogOfWar.gd`
