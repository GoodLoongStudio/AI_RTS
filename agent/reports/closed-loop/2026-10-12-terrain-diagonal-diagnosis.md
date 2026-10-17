# 地形斜线归因记录（2026-10-12）

结论：用户截图中的密集斜线可在当前源码的真实 Match 中复现，来自地形自阴影的深度比较伪影（shadow acne）。当前大地图呈现将太阳阴影偏移 `shadow_bias` 覆盖为 0.04；同机、同相机的测试仅将其改为 0.3，条纹消失，同时建筑和无人机仍有正常阴影。当前仅完成诊断，没有修改游戏产品代码，不能称为修复已交付。

## 工程与实例

- 开发根：G:/AIRTS/AI_RTS；Git 根和 `check_workspace_target.py` 均确认，检查 rc=0。
- 用户实例：初始 PID 15076，后续自行重启为 PID 43084。CIM 命令行与 MCP 均确认 --path G:/AIRTS/AI_RTS；后者只读查询和截屏，测试结束仍在运行。
- 用户新实例运行生成地图 36-1846106761-767a002977，实际参数：Forward+/Vulkan、shadow_bias=0.04、shadow_normal_bias=1、SSAO=false、SSIL=false、旧黑垫板不可见。它与复现场景共用 GeneratedTerrain 和 showcase_land.gdshader。
- 自有测试 PID 34236，在独立 Windows 桌面 AIRTS_DIAGONAL_42976 渲染，不切换用户桌面、无 OS 输入。加载正常 Match.tscn、PlainAndSimple 512m 地形和真实开局单位。诊断相机 size=53.25，冻结同一对局状态进行 8 组单变量截图。

## 对照结果

| 测试 | 斜线 | 正常单位/建筑阴影 |
|---|---|---|
| 原参数 0.04 | 明显存在 | 保留 |
| 关闭太阳阴影 | 消失 | 消失，仅用于归因 |
| 恢复太阳阴影 | 重现 | 保留 |
| 仅 shadow_bias 改成 0.3 | 消失 | 保留 |
| 仅地形不投射阴影 | 消失 | 保留，仅用于归因 |
| 仅地形 normal_strength=0 | 仍存在 | 保留 |
| 仅隐藏战争迷雾覆盖 | 仍存在 | 保留 |
| 全部恢复基线 | 重现 | 保留 |

截图均为当前新鲜产物，保存 rc=0，已实际打开基线、无阴影、0.3、地形不投影、无法线和无雾覆盖画面；比较图也已打开核对。截图：[对照图](../../runs/20261012-terrain-diagonal/comparison.png)、[基线](../../runs/20261012-terrain-diagonal/01-baseline.png)、[仅偏移 0.3](../../runs/20261012-terrain-diagonal/04-bias-0p3.png)。

## 来源与修复方向

- 触发参数：source/match/Match.gd:475，`_apply_large_map_playable_presentation()` 写入 `sun.shadow_bias = 0.04`，覆盖 Match.tscn:224 的 0.3。
- 投影对象：source/match/maps/generated/GeneratedTerrain.gd:1338 将地形设置为投射阴影。大地面同时投射和接收自身阴影，当前偏移不足，使微小深度误差成为规则条带。
- 推荐下一轮先验证恢复合适偏移，保留地形、建筑、单位阴影和原贴图。0.3 是本轮成功诊断值，尚未验证所有山地、坡面、相机缩放与阴影接地效果，不能直接宣称是所有地图的最终值。

## 验证与限制

- 命令：`python agent/runs/20261012-terrain-diagonal/driver.py`，rc=0；Godot 正常退出 rc=0；8 张截图均刷新；cleanup_ok=true；独立 CIM 核验自有 PID 已不存在，用户 PID 43084 仍运行。
- 原始证据：[driver-result.json](../../runs/20261012-terrain-diagonal/driver-result.json)、[metadata.json](../../runs/20261012-terrain-diagonal/metadata.json)、[live-properties.json](../../runs/20261012-terrain-diagonal/live-properties.json)、[probe.log](../../runs/20261012-terrain-diagonal/probe.log)。
- 日志并非无错误：开局有 navigation map_index<0，退出有地形/障碍清理的 is_inside_tree 错误和资源释放警告。8 组截图均在退出错误前完成。此次仅用来归因，不能据 rc=0 宣称玩法回归或对局生命周期验收通过；未修这些问题，也未断言它们与斜线有关。
- 未运行玩法全量回归、未测全部生成地图/全部缩放、未做产品补丁或性能收益认证。未创建 candidate/champion，连续未提升轮数不适用于此只读诊断。
- 共享工程有大量其他任务未提交改动；本轮只写 agent/plans、agent/reports 和 agent/runs 下的独立任务文件，没有回滚、覆盖、打包或结束用户进程。
