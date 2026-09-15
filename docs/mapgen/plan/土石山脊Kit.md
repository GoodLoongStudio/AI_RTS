# 土石山脊 Kit

2026-09-10：建立用于高阻碍物的长条土石山脊独立组件，等待用户视觉验收。

- 入口：`tools/godot/earth_ridge_component.gd`。
- 参数：`tools/godot/earth_ridge_parameters.json`，当前长度 112m、宽度 46m、高度参数 25m，固定 seed 91026。当前采样画布为 128×76m，参数修改须保证轮廓不触及边界。
- 连续高度场生成起伏山脊、侧沟、收束端头及自然山脚；使用正式砂地/岩石贴图与法线，复用台地样例光照。散石来自已有西部土著 `SM_Env_RockFlat_03`。
- 输出：`review/G4/kit_samples/earth_ridge_prototype/`，包含可实例化 `earth_ridge.tscn`、三张 Godot 实拍、参数实例清单 `component.json`、候选占地 `footprint.json`。
- 这是高阻碍物视觉和碰撞原型。G2 blocking、不可建设标记、导航和 G4 自动摆放尚未接入；候选 footprint 不能替代权威 G2 数据。

## 重建与验证

截图必须使用实际图形后端。无显示的 headless 模式不会产生有效帧；生成脚本会拒绝该模式。

```powershell
& G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe --path G:/AIRTS/RTS_Map_Tool --script res://tools/godot/earth_ridge_component.gd --rendering-method gl_compatibility --display-driver windows
& G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe --headless --path G:/AIRTS/RTS_Map_Tool --script res://tools/godot/verify_earth_ridge.gd
```

已校验真实三视图：正反面完整，山脚无断缝、悬空薄片、青绿色边缘。场景重载及三个山体碰撞射线采样单独记录于 `verification.json`，不代表寻路或整图性能验收。

## 追加组合（2026-09-10）

用户已认可长条山脊，追加弧形山脊 `arc_ridge`、错列双山脊 `offset_ridges`、独立山群 `mountain_cluster` 三种组合。保持原版的贴图、法线、粗糙度和光照；组合定义由 `tools/godot/earth_ridge_combinations.json` 驱动。

- 生成入口：`tools/godot/earth_ridge_combinations.gd`，沿用上面非 headless 截图命令，只替换 script 路径。
- 输出：`review/G4/kit_samples/earth_ridge_combinations/<id>/`，每组含 `component.tscn`、整体/俯视 PNG、参数实例清单和占地采样。
- 校验：`tools/godot/verify_ridge_combinations.gd`，使用 headless 验证保存场景加载及每组山体射线采样。
- 山间空地不生成山体碰撞三角形。候选占地按每行多段记录，保留山体之间的空隙。
- 三组均为独立视觉/碰撞组合，等待用户验收；尚未接入 G2/G4 或验证导航。
