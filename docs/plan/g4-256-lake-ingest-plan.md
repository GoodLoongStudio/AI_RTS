# G4 大湖 256×256 重生 Implementation Plan

## Overview
把 seed16 大湖做成 **256×256** 整条 G1–G4：台地 6 座、坡口 12m，挂进自定义对局。512 旧包已删除，四人图不再出 512。

## Current State Analysis
- 512 评图 `16-0-7d337ce8be` 真机约 1–2 FPS。高度场 1025²、作者碰撞数百个。
- 128 正式 G2 把湖/河/台地搜空，来不及出图。
- 256 是 G1/G2 原始设计尺度（`min_pair` 89.6m），空间约为 128 的 4 倍。
- 游戏大地图锁门槛是 `map.size >= 256`：256 会关迷雾/阴影、跳过导航烘焙、不导出 Walk 板。
- 高度场约 513²（upsample=2），顶点约为 512 图的 1/4。

## Implementation Strategy
1. `contract.apply_map_extent(256)` 只作用于本次进程。
2. 正式 G1→G2（6 座台地、12m 坡口、单河+大湖）→G3→G4 `natural`。
3. G2 失败则确定性烘焙一张可玩 256 湖图，保证本轮能装机。
4. 不调用 `install_runtime_scripts()`，避免旧副本覆盖游戏内 `GeneratedTerrain.gd`。
5. 新 `map_id` 写入 `MatchConstants.MAPS`。

## Implementation Steps
1. 写 256 计划与 `tools/regen_large_lake_256.py`
2. 放宽 256 尺度下的湖口袋搜索
3. 跑 G1–G4 并装机
4. 挂菜单、小地图回退不再写死旧 map_id

## Timeline
本轮生成并挂菜单；用户进自定义对局选新大湖测帧率。

## Risk Assessment
- 256 仍走大地图锁，单位导航可能不烘焙；先验证进局与帧率。
- 双家出生台地 + 贯图河仍可能把湖搜空，脚本内有只湖 / 烘焙兜底。
- 不改全局 `contract.W`。

## Success Criteria
- `map.size` 为 256×256，高度场边长 ≤ 513
- 台地约 6 座，坡口标称 12m，可见大湖
- 菜单能选，开局可操作、不再是 1–2 帧

## Progress Tracking
- ✅ 计划
- ✅ 脚本与湖搜索容错
- ✅ 带桥图 `16-0-1ca6e21aa1` 装机
- ✅ 加载失败：去掉未导入的 `terrain_masks.png` Texture2D 依赖；256 不再写水面片
- ✓ 生成不再空等：Numba warmup 打时、G2/G3 命中缓存跳过、每 attempt 打进度
- ✓ 台地坐标：点击沿高度场求交；镜头/出生用 sample_height；大图建造不再依赖空 navmesh
- ✓ 小地图：G2 语义俯视写成 `minimap_preview.png`，装进 `assets/map_previews`
- ✓ 256 战争迷雾恢复：主画面 + 小地图共用 CombinedViewport，视口封顶 512²

## Related Files
- `RTS_Map_Tool/rtsmap/contract.py`
- `RTS_Map_Tool/tools/regen_large_lake_256.py`
- `RTS_Map_Tool/rtsmap/gates/g2_strategy.py`
- `RTS_Map_Tool/rtsmap/gates/g4_export.py`
- `AI_RTS/source/match/MatchConstants.gd`
- `AI_RTS/source/match/hud/Minimap.gd`
