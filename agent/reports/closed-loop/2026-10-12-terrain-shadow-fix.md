# 地形斜线修复闭环报告

状态：本任务视觉/运行时目标通过；全量项目回归 `needs-review`。

开发根为 `G:/AIRTS/AI_RTS`，路径检查为 `python tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS`，rc=0。没有修改 `G:/AIRTS/打包版`，没有结束用户运行实例。工作区原本有大量其他未提交修改，本轮没有 reset、clean、checkout 或整文件回滚。

## 改动

本补丁只处理 `source/match/Match.gd` 的大地图灯光初始化：删除 `_apply_large_map_playable_presentation()` 对 `sun.shadow_bias = 0.04` 的覆盖，保留阴影开启、最大距离 80、normal bias 1.0 和 pancake 8.0。`source/match/Match.tscn:224` 的 `shadow_bias = 0.3` 成为唯一运行时口径。

本补丁没有改地形 shader、贴图采样、雾、地形网格、碰撞、导航或玩法。测试驱动的可选场景参数、剩余诊断探针和证据整理脚本只在 `agent/runs/20261012-terrain-shadow-fix`，不接入游戏启动链路。复验提示词在 [2026-10-12-terrain-shadow-fix-replay.md](../../prompts/2026-10-12-terrain-shadow-fix-replay.md)。

## 证据

- 源码静态搜索：仅有 `Match.tscn:224 shadow_bias = 0.3`；`Match.gd` 不再写入 bias，`PerformanceGovernor` 也没有覆盖它。
- 独立真实 Match headless：rc=0，marker 通过，开局 `command_center + drone`，无人机移动命令 `Accepted`，实际位移 11.20m/4.0s，退局后重开仍为 `shadow_bias=0.3`，cleanup 通过。证据：[headless-isolated-final/driver.json](../../runs/20261012-terrain-shadow-fix/headless-isolated-final/driver.json)、[result.json](../../runs/20261012-terrain-shadow-fix/headless-isolated-final/result.json)。
- 独立 GPU 可见实例：平地图和生成地图均为 Forward+/Vulkan，四档相机缩放均保存截图；生成图材质绑定 `mask_world_size=512`，无新的 bias 覆盖。证据：[generated-isolated-final/driver.json](../../runs/20261012-terrain-shadow-fix/generated-isolated-final/driver.json)、[generated-final-diagnosis/result.json](../../runs/20261012-terrain-shadow-fix/generated-final-diagnosis/result.json)。
- 同一冻结画面对照：运行时改回 0.04 会出现规则密集斜线；恢复 0.3 后消失，建筑和无人机投影仍存在。已打开并检查：[comparison-final.png](../../runs/20261012-terrain-shadow-fix/comparison-final.png)。
- 独立复核两轮均读取 `shadow_bias=0.3000000119`、阴影开启，源文件前后 SHA-256 不变。证据：[independent-report.md](../../runs/20261012-shadow-independent/independent-report.md)。
- 本轮自有探针进程均已清理，用户实例未操作。证据：[cleanup-recheck-final.json](../../runs/20261012-terrain-shadow-fix/cleanup-recheck-final.json)。

## 回归门禁

回归运行器按 `config/full_regression_suite.json` 启动了 127 项；第一批期间共享工作区又出现 `DebugControlServer.gd`、`GeneratedTerrain.gd` 等其他任务修改，后续长测也因既有解析、配表断言、脚本/资源清理和超时问题失败，未形成单一冻结树的全绿结果。聚合证据为 123 项有结果、46 项严格通过、77 项失败、4 项未完成；这组数据只用于透明记录，不能作为本阴影补丁的回归结论：[regression-aggregate-final.json](../../runs/20261012-terrain-shadow-fix/regression-aggregate-final.json)。

已确认的非本补丁失败包括：`BalanceConfigRuntime` 既有成本/载荷断言、`PerformanceGovernor` 既有规则断言、`DebugControlServer`/测试夹具解析或空节点错误、Dummy 渲染器纹理空参数、多个套件退出资源仍在使用，以及部分移动/导航超时。没有修改这些判据，也没有把它们标绿。

## 结论与限制

这次不是“修改被覆盖”：当前源码、两轮独立 headless 和当前可见实例都使用 0.3。用户附图时间早于本补丁写入时间，因此它展示的是旧进程/旧参数画面。关闭后重新启动 `G:/AIRTS/AI_RTS` 的开发实例后，应以运行时值和新画面为准；若重启后的同一画面仍出现同样密集斜线，应提供新截图/新进程时间，因为当前独立 GPU 对照已排除固定 shader/贴图条纹。

未验证项：全量项目回归在单一冻结工作树上的完整绿；所有生成地图、所有坡面角度和所有驱动器的长期阴影接地质量；这些不影响本轮已复现的 0.04→0.3 斜线归因，但不应扩大结论。
