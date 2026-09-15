# AI_RTS

Godot .NET 正交俯视 RTS。地图生成管线在本仓库 `tools/mapgen`，不依赖兄弟目录。

## 引擎

- Godot **4.7.x .NET（Mono）**，安装包文件名含 `_mono_`
- 本机还需 **.NET SDK 8.0+**
- 只用 `Godot_v*-stable_mono_win64.exe`（或对应 `_console.exe`）打开本目录

团队契约小版本曾对齐 4.3；本工程 `project.godot` 当前 features 为 4.7。

## 只玩

用 Godot .NET 打开本仓库，选已装地图进局。不需要 Python。已装图在 `source/match/maps/generated/`，模型在 `assets/models/scifi-worlds/`。

`初选素材包/` 含商用 FBX，默认不提交。公开仓库前必须先定素材授权。

## 生成新图

1. 安装 Python 3.11+
2. 在 `tools/mapgen` 跑 `.\setup.ps1`
3. 游戏内「地图生成」，或 `python serve_g2.py --port 8766`

本机 Godot 路径可写环境变量 `RTSMAP_GODOT`，或放 `tools/mapgen/rtsmap/workbench/engine.local.json`（已 gitignore）。

## GitHub

本仓库已是独立 git 根。远程仓库名和公开/私有未定，不自动创建或推送。指定后再绑。
