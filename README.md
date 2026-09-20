# AI_RTS

Godot .NET 正交俯视 RTS。地图生成管线在本仓库 `tools/mapgen`，不依赖兄弟目录。

## 引擎

- Godot **4.7.x .NET（Mono）**，安装包文件名含 `_mono_`
- 本机还需 **.NET SDK 8.0+**
- 只用 `Godot_v*-stable_mono_win64.exe`（或对应 `_console.exe`）打开本目录

团队契约小版本曾对齐 4.3；本工程 `project.godot` 当前 features 为 4.7。

## 只玩

用 Godot .NET 打开本仓库，选已装地图进局。不需要 Python。已装图在 `source/match/maps/generated/`，模型在 `assets/models/scifi-worlds/`。

> clone 前请先装 **Git LFS**（`git lfs install`）：模型/贴图/音频由 LFS 存储，未装 LFS 时拿到的是指针文本，游戏资源会缺失。

商用素材源包 `初选素材包/` **不在本仓库**（2.8GB 商用 FBX 源包，2026-09-20 移出以降低仓库负担）；游戏运行与打包都不需要它。

## 打包成 Windows 包

想打出一个「双击即玩、玩家无需装任何东西」的单文件 exe：见 **[PACKAGING.md](PACKAGING.md)**
（环境准备、导出模板下载与已知坑、验证清单、一键脚本 `tools/build_windows.ps1`）。

## 生成新图

1. 安装 Python 3.11+
2. 在 `tools/mapgen` 跑 `.\setup.ps1`
3. 游戏内「地图生成」，或 `python serve_g2.py --port 8766`

本机 Godot 路径可写环境变量 `RTSMAP_GODOT`，或放 `tools/mapgen/rtsmap/workbench/engine.local.json`（已 gitignore）。

## GitHub

- 远程：`https://github.com/GoodLoongStudio/AI_RTS`（Public，默认分支 `main`，MIT）
- 开发分支 `yyp_test`，代码与 `main` 保持同步；打包/分发指引见 `PACKAGING.md`
