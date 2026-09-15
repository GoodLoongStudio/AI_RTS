# G2 预览对齐 G4 材质 Implementation Plan

## Overview
把 G2 俯视底图（工作台「地形逻辑」、`minimap_preview.png`、大厅预览）改成 G4 `showcase_land` 同系材质：沙地、深青水面、干尘台顶、岩壁，不再用平涂蓝/橙色块。

## Current State Analysis
`plots_g2._base_height_image` 用固定 RGB：水 `(28,102,188)`、台地 `(208,140,48)`、平地米白。游戏小地图直接吃这张图，所以和局内沙地/深水对不上。G2 高程已是地面 0.6 / 水 -2.4 / 台顶 8.1，旧阈值 `height>3` 还会把坡道涂错。

## Implementation Strategy
1. 从 `assets/terrain_pbr` 采样 G4 同款贴图（`dense_sand`、`moon_dusted`、`cliff_side`、`dark_rock`、`damp_beach`）。
2. 按契约高程分层，加坡度阴影，水面用 G4 的深青而不是亮蓝。
3. Overview / 小地图共用同一底图；G4 装机若已有 `height_data.bin` 则用真实高度场出小地图。
4. 重绘当前 256 大湖预览，不改生成几何。

## Implementation Steps
1. 写 `viz/g4_style.py` 材质合成
2. `plots_g2` 改走新底图，图例同步
3. G4 `write_minimap_preview` 可吃高度场
4. 重装 `16-0-1ca6e21aa1` 预览
5. 加颜色契约测试

## Timeline
本轮完成着色与现图预览更新。

## Risk Assessment
贴图缺失时回退到 G4 shader 的固态色，不回到亮蓝橙。不调用 `install_runtime_scripts()`。

## Success Criteria
- G2 overview / 小地图水面偏深青，平地是沙色颗粒，台顶是干尘土
- 现装 256 大湖小地图与大厅预览已更新
- 几何与 map_id 不变

## Progress Tracking
- ✅ 计划
- ✅ 材质合成（`viz/g4_style.py` 采样 `terrain_pbr` + 坡度分层）
- ✅ 接入 G2 overview / 小地图 / G4 `write_minimap_preview`
- ✅ 重绘 `16-0-1ca6e21aa1` 大厅与局内小地图
- ✅ `tests/test_g2_preview_style.py` 通过

## Related Files
- `tools/mapgen/rtsmap/viz/g4_style.py`
- `tools/mapgen/rtsmap/viz/plots_g2.py`
- `tools/mapgen/rtsmap/gates/g4_export.py`
- `source/match/maps/generated/16-0-1ca6e21aa1/minimap_preview.png`
- `assets/map_previews/map_16-0-1ca6e21aa1.png`
