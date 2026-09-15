# 把 G1–G4 迁进 AI_RTS 独立仓库 Implementation Plan

## Overview
把 `RTS_Map_Tool` 的有用源码迁到 `AI_RTS/tools/mapgen`，去掉 `G:\` 绝对路径，让游戏仓库自包含。不拷 review / venv / 本机产物。不自动建 GitHub 远程。

## Current State Analysis
菜单「地图生成」写死去找兄弟目录 `RTS_Map_Tool`。G4 写出死 `G:\AIRTS\AI_RTS` 和本机 Godot 路径。别人 clone 后无法生成新图。

## Implementation Strategy
1. 拷 `rtsmap`、`serve_g2.py`、`requirements-g2.txt`、`tests`、`tools` 到 `tools/mapgen`。
2. `G4_AIRTS` / Godot / 初选素材改为工程根发现。
3. `MapGeneration.gd` 指向 `res://tools/mapgen`。
4. `setup.ps1` + gitignore + README；禁止 `install_runtime_scripts()` 覆盖游戏脚本。
5. venv pytest 与装机冒烟。

## Implementation Steps
1. 拷贝有用源码
2. 相对路径
3. 安装脚本与文档
4. 验收

## Timeline
本轮完成迁入与路径解耦。GitHub 远程另议。

## Risk Assessment
- 包内旧 `GeneratedTerrain.gd` 若被安装会回滚游戏脚本。
- 初选素材包不进 git。
- 原 `RTS_Map_Tool` 只加指向说明，不删。

## Success Criteria
- 不依赖兄弟目录即可拉起生成服务
- `tools/mapgen` venv 里 pytest 通过
- 仓库默认路径无 `G:\AIRTS\...`

## Progress Tracking
- ✅ 计划
- ✅ 拷贝
- ✅ 相对路径
- ✅ 安装脚本与文档
- ✅ 验收（venv + bootstrap + 导出装机 + 256 大湖进局）
- ✅ GitHub 远程不自动创建；已有 origin，等你点名再推

## Related Files
- `AI_RTS/tools/mapgen/`
- `AI_RTS/source/main-menu/MapGeneration.gd`
- `AI_RTS/.gitignore`
- `RTS_Map_Tool/README.md`
