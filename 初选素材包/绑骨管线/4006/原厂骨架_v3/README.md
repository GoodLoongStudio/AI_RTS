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

本版 Fire 是端枪后坐；Hit 是 0.3s 快速中弹顿挫，第 1 帧达到冲击峰值；HitHeavy 是 1.8s 爆炸击飞死亡，包含腾空后抛、落地滑停及最后 0.4s 死亡定格。Crawl 是单手携枪。

游戏已区分步枪子弹与炮弹/火箭的命中表现。连续中弹会重新触发 Hit；致死爆炸播 HitHeavy，其余致死伤害播 Death。单位立即退出战斗，仅死亡视觉继续播放，结束停留 1s 后清理，不会炸飞后恢复站立。未致死的伤害不会强制杀死单位。

当前不是全部角色批量定版，也未宣称任意速度无滑步或近景手指达到最终美术标准。爆炸采用编制轨迹，落点基于单位脚下平面，尚未做斜坡贴地或布娃娃物理。
