# 256 大湖战争迷雾恢复 Implementation Plan

## Overview
256 生成图重新打开战争迷雾，小地图 FogOfWarMask 与主画面共用 CombinedViewport 纹理。大气高度雾片、体积雾、阴影锁保持关闭。

## Current State Analysis
- `map.size >= 256` 时 `_lock_large_map_before_first_frame` / `_apply_large_map_playable_presentation` 会关掉 FogOfWar 并 `free` CombinedViewport。
- 小地图因此隐藏 FogOfWarMask，只剩 G2 预览或黑框。
- 256×2px/m = 512²，原先 2048m/4096² 全黑的问题不成立。

## Implementation Strategy
1. 大图锁只关高度雾片、体积雾、阴影；战争迷雾仅在 `Visibility.FULL` 时关。
2. Fog 视口边长封顶 512，避免再涨到 1024²。
3. 侧栏收编小地图后，把 FogOfWarMask 的 `reference_texture` 绑回 CombinedViewport。

## Implementation Steps
1. Match：拆开战争迷雾与大图表现锁
2. FogOfWar：resize 封顶并回写 overlay 纹理
3. Minimap：大图保留遮罩并同步纹理
4. 更新 256 计划进度

## Timeline
本轮改完即可进局验收。

## Risk Assessment
- ScreenOverlay 用深度还原世界 XZ；台地顶 XZ 仍正确。
- ViewportTexture 在小地图换父后会断，必须运行时重绑。

## Success Criteria
- 主画面未探索为黑雾，己方视野内可见
- 小地图同一套开雾，底图仍是 G2 预览
- FULL 可见性仍无迷雾
- 256 进局不明显掉帧
- 四人 G4 图统一 256×256，不再保留 512 评图

## Progress Tracking
- ✅ 计划
- ✅ Match 拆锁
- ✅ FogOfWar 封顶
- ✅ 小地图同步
- ✅ 文档

## Related Files
- `AI_RTS/source/match/Match.gd`
- `AI_RTS/source/match/FogOfWar.gd`
- `AI_RTS/source/match/hud/Minimap.gd`
- `AI_RTS/docs/plan/g4-256-lake-ingest-plan.md`
