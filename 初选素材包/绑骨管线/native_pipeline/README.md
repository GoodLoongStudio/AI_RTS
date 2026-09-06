# 4006 原厂骨架单角色动画管线

入口为 `build_native.py`，目标角色为原始 `Characters.fbx` 中的 `SM_Chr_ScifiWorlds_Soldier_Male_01`。不使用旧 `*_rigged.fbx`，不改身体网格顶点、原始 50 骨架 rest 或蒙皮权重。

运行（PowerShell，Blender 5.0.1）：

```powershell
& 'C:\Program Files\Blender Foundation\Blender 5.0\blender.exe' --factory-startup -b --python .\build_native.py
& 'C:\Program Files\Blender Foundation\Blender 5.0\blender.exe' --factory-startup -b --python .\validate_native.py
& 'C:\Program Files\Blender Foundation\Blender 5.0\blender.exe' --factory-startup -b --python .\render_native.py
python .\make_previews.py
```

输出到 `../4006/原厂骨架_v3/`。`build_native.py -- --review` 可额外输出少量 Blend 审核帧，正式 GIF 则来自 `render_native.py` 对最终 GLB 的重新导入。模型包内只有身体和完整步枪，枪的弹匣、瞄具、扳机部件都合并并统一米制。

## 旋转与时间约定

每骨使用 `Q_align * Q_source_pose * inverse(Q_source_reference) * inverse(Q_align)` 得到共同世界坐标下的动作增量，应用到目标原始 rest；再依据目标父骨已解旋转与目标相对 rest 求局部旋转。每帧重置非动画通道，非根骨不拷贝平移。这里不是裸 COPY_ROTATION，也不是在不同骨骼轴下直接复制局部四元数。

统一以 30fps 导入/采样，并在武器 FBX 导入之后再次固定 30fps（FBX 可覆盖场景 FPS）。关键帧从 0 开始，源/GLB/Godot 三方都断言实际时长；完整源动作时间从 action frame_range 读取。Idle/Run/Crawl 末帧与首帧一致，循环周期只烘焙一遍。游戏移动仍由导航控制，动画 Hips 不累计水平位移。

## 七段动作

| 剪辑 | 来源/处理 | 长度 |
|---|---|---|
| Idle | 本地 Soldier Idle + 双手步枪握持 IK | 1.9667s |
| Run | 本地 Soldier Run + 随胸肩变化的双手握持 IK | 0.7s |
| Fire | 本次编制的端枪瞄准/短后坐层，身体使用 Idle 参考帧 | 0.6s |
| Hit | 本次编制的站立轻受击层，双手保留握枪 | 0.7s |
| HitHeavy | 本次编制的较强站立后仰/扭转，不是击飞倒地 | 0.9s |
| Crawl | 本地 UAL Crawl_Fwd 的完整 65/30s 周期，右手携枪 | 2.1667s |
| Death | 本地 UAL Death01，右手携枪、终帧保持倒地 | 2.4s |

`rifle_hold` 以同一把枪的两个握持点求左右臂 IK；枪顶点只受 Hand_R 权重 1.0 影响，是刚体随动，不会弯曲。未额外加入控制骨。若以后需要换枪，可把同样的局部变换迁移到 Godot BoneAttachment3D；本版已验证内嵌枪的导出稳定性。

## 验证边界

`validate_native.py` 验证原始身体权重、50 骨架、每段真实关节运动、所有循环关节首尾闭合、水平根运动、身体/枪地面穿透、枪相对右手的刚性，以及 GLB 重新导入与 Blend 的误差。验证的是可重复的技术条件，不会自动判断动作是否有足够力量感、手指是否达到近景美术标准、脚掌在任意游戏速度下是否完全无滑步。

已有来源是工作区内资产，未下载新商业素材：原始角色和枪来自 PolygonSciFiWorlds；Soldier.glb 为原管线已有素材（本次未补齐原始许可档）；UAL 来自已有 Quaternius 数据。发行授权仍以项目素材来源登记为准，本次没有做新授权结论。
