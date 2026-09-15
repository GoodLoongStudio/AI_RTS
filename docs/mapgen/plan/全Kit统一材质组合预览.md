# 全 Kit 统一材质组合预览

2026-09-10：按用户要求，在一个连续场景中组合已审核组件，检查统一材质后的整体效果。

- 入口：`tools/godot/all_kits_showcase.gd`。复用台地、河湖和桥原型生成函数，以及四种保存的土石山脉场景；不改写单组件基线。
- 地表：台地/坡道、山脉、河岸和湖岸共用 `unified_sandstone.tres`，统一砂岩/砂土贴图、世界坐标纹理密度、法线和粗糙度。地面使用同源材质，附加水域裁剪。
- 水体：河与湖使用同一套水面 shader 和颜色，降低统一光照下的高亮及白色岸线；水形状遮罩改为局部坐标以支持平移。
- 光照：全场只有一组环境光和太阳光，沿用已验收山脉参数。桥保留金属 Kit 材质。
- 摆放：河道贯穿场景，桥跨河；台地位于北岸，湖泊位于南岸独立洼地，长山脊/弧形/双山脊/山群分布两岸。背景平面裁剪出水域，移除原组件多余的平面三角形，避免覆盖河面和出现方形材质接缝。
- 输出：`review/G4/kit_samples/all_kits_showcase/` 内含 `all_kits.tscn`、共享材质、四视图、组件实例记录及重载校验结果。
- 本轮是组合视觉场景，不是 G2 自动生成或导航验收；没有修改 G2 blocking、passable 或水域权威数据。

```powershell
& G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe --path G:/AIRTS/RTS_Map_Tool --script res://tools/godot/all_kits_showcase.gd --rendering-method gl_compatibility --display-driver windows
& G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe --headless --path G:/AIRTS/RTS_Map_Tool --script res://tools/godot/verify_all_kits_showcase.gd
```

查看 `overview.png` 了解全组件布局，`plateau_bridge.png` 检查台地坡道与桥，`lake_mountains.png` 检查湖岸及山脚，`top.png` 检查占地关系。均由 Godot 图形后端直接输出，无图像重绘。
