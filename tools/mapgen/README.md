# tools/mapgen

AI_RTS 内的 G1–G4 地图生成管线（原 `RTS_Map_Tool` 有用源码）。运行产物写到本目录 `workbench_output/`，装机仍写 `source/match/maps/generated/`。

## 安装

需要 Python 3.11+。在本目录执行：

```powershell
.\setup.ps1
```

会创建本地 `.venv-g2`（已 gitignore）。

## 生成

```powershell
.\.venv-g2\Scripts\python.exe serve_g2.py --port 8766
```

游戏菜单「地图生成」会拉起同一服务。也可：

```powershell
.\.venv-g2\Scripts\python.exe run.py --gate G1 --seeds 16
```

不要调用 `install_runtime_scripts()`。包内 `rtsmap/data/godot_scripts/GeneratedTerrain.gd` 是旧副本，会盖掉游戏内带 `semantic_span` 的版本。

## 路径

默认不再写盘符。工程根从本目录向上找 `project.godot`。Godot Mono 按 `RTSMAP_GODOT` → `rtsmap/workbench/engine.local.json` → PATH / 工程旁 `*mono*_console.exe`。初选素材在 `初选素材包/工程/预览渲染工程`（相对工程根，该目录默认不进 git）。

## 测试

```powershell
.\.venv-g2\Scripts\python.exe -m pytest -q
```
