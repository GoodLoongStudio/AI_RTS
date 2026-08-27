# 单位建筑遮挡虚化 Implementation Plan

## Overview
镜头到单位的视线被高大建筑挡住时，把该建筑改成半透明，直接露出后面的单位。

## Current State Analysis
单位剪影方案未生效：选中圈和血条仍能看见，车身完全被灰模柱子挡住。战役建筑是 `Map/Decorations` 里的实心盒子，没有碰撞。

## Implementation Strategy
每帧用镜头到单位的线段测建筑世界 AABB。命中则给该网格换半透明材质副本，离开后恢复。只处理高度 ≥ 1.5 的装饰物和己方/敌方建筑。

## Implementation Steps
1. ✅ 去掉未生效的单位剪影
2. ✅ `BuildingOcclusionFade` 按视线虚化建筑
3. ✅ 冒烟：柱子挡住坦克则半透明，移开后恢复
4. ✅ 2026-08-25 建筑虚化已验收
5. ✅ 单位剪影残留已清理

## Timeline
只改显示，不改点击和寻路。

## Risk Assessment
共用材质会先复制再改 alpha，避免整张地图一起变透明。道路等扁网格不会被当成遮挡物。

## Success Criteria
- 坦克转到灰柱后面时，柱子变虚、车身可见
- 走开后柱子恢复实心

## Progress Tracking
✅ 建筑虚化
✅ 冒烟
✅ 人工验收
✅ 剪影代码清理

## Related Files
- `source/match/handlers/BuildingOcclusionFade.gd`
- `source/match/Match.tscn`
- `tests/automated/BuildingOcclusionFadeSmokeTest.gd`
