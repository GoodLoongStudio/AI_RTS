# 山体形态 + 坡道开口 Implementation Plan

## Overview
山要看出主脉，坡道必须是台地轮廓里切开的 U 形缓坡口：沙地保持平坦，不要外凸尖锥，也不要俯视大方槽。

## Current State Analysis
- 山：分块 `dmax` + 主脊后峰约 51.8 语义米 / 207 世界米（g132/g133）。
- g131：矩形带切台顶 → 俯视方缺口；侧视已有三角楔。
- g132（失败）：浅切 3 格 + 顶窄脚宽扇形铺到沙地 → 崖壁乳头状尖锥。用户一眼能看出来，数字探针看不出来。
- g133：坡脚锚台缘、向内切 15 格、U 形湾、沙地最多外扩 1 格。特写沙地已平，俯视是圆角湾。

## Implementation Strategy
1. **山**：连通块自己的 `dmax` 起峰；主脊加权；去掉 face 毛巾纹。不重跑 G2。
2. **坡道**：在台地里切开 U 形口。禁止扇形铺沙地，禁止宽矩形带深切成方槽。

## Implementation Steps
1. ✅ 改 `g4_terrain_mountains.mountain_addon`
2. ❌ g132 扇形铺沙地（视觉否决）
3. ✅ 改 `g4_terrain`：向内 U 形湾 + 沙地不堆锥
4. ✅ 导出并装机 `height_data.bin`，出 `g133_*`

## Timeline
公式 → 出图 → **用眼睛看特写** → 再改。

## Risk Assessment
- U 湾口过宽：圆台俯视像缺了一块饼干
- 个别坡口从俯视仍略尖
- `max_step_walkable` 需保持可走

## Success Criteria
- 特写：沙地无锥、崖壁是开口缓坡
- 俯视：圆角湾，不是方槽、不是尖楔
- 主峰与山脚保底保持 g132 山体结果

## Progress Tracking
- ✅ 山体（峰 51.8 语义米）
- ❌ g132 扇形坡道（视觉否决：尖锥）
- ✅ g133 U 形内切（`g133_ramp_se` / `g133_ramp_central` / `g133_plateau_ramp` 已用眼睛核对）
- ⏳ 用户看 g133 是否还要收口或改坡长

## Related Files
- `RTS_Map_Tool/rtsmap/gates/g4_terrain_mountains.py`
- `RTS_Map_Tool/rtsmap/gates/g4_terrain.py`
- `RTS_Map_Tool/review/G4/g2_large_lake_kits/g133_*.png`
