# 4006 原厂骨架动画 v3

这是一个标准士兵的可审核基线，保留原始 50 骨骼/身体权重，并携带完整步枪。七段：Idle、Run、Fire、Hit、HitHeavy、Crawl、Death。

- `Infantry_native_v3.glb`：可导入 Godot 的成品；原生朝向 +Z，游戏挂载需绕 Y 转 180°。
- `Infantry_native_v3.blend`：可逐段检查的烘焙工程。
- `动画审核/`：最终 GLB 重新导入后生成的 GIF、胶片条和索引。
- `打开动画审核.ps1`：启动独立 Godot 4.7.1 审核窗口，可选择七段/暂停。
- `validation.json`：Blender 与实际 GLB 的技术验证。
- `godot_review/godot_validation.json`：Godot 导入、实际关节运动、CPU 蒙皮地面检查。
- `source_integrity.json`：原始权重及源文件哈希。
- `../../native_pipeline/`：重建、验证和预览脚本。

本版 Fire 是编制的端枪后坐；Hit/HitHeavy 是保留握枪的站立受击，重击尚不包含击飞和起身；Crawl 是单手携枪。死亡资产可播放，但游戏原有死亡时立即销毁单位的逻辑仍需另行设计。当前不是全部角色批量定版，也未宣称脚掌 IK、任意速度无滑步或近景手指都达到最终美术标准。
