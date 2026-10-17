# 副官与地图生成流程图提示词审查记录（2026-10-11）

## 任务范围

本轮仅生成给另一个 AI 使用的本地计划和提示词，没有修改游戏源码、没有启动新的真实 Match、没有录制视频，也没有修改打包版。

提示词：[总提示词](../../prompts/2026-10-11-adjutant-map-progress-followup-deepseek.md)

计划：[分阶段计划](../../plans/2026-10-11-adjutant-map-progress-followup-plan.md)

## 当前证据快照

- 工作区目标检查：`python tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS`，allow。
- 当前源码和历史运行证据快照：[review_snapshot.json](../../runs/20261011-adjutant-map-review/review_snapshot.json)。快照明确标记为 `source_and_historical_evidence_review_no_new_match`。
- 副官相关 Python 回归：`G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe -m unittest adjutant_coordinator.tests.test_safe_movement adjutant_coordinator.tests.test_forward_rally adjutant_coordinator.tests.test_development_ladder`，cwd=`G:/AIRTS/AI_RTS/source`，132 tests，rc=0。原始日志：[python-related-tests.log](../../runs/20261011-adjutant-map-review/python-related-tests.log)。
- 历史 Godot 结果：AutomaticConstruction=0、SameFrameOverlap=0；OreRefinery=2、RuntimePlacement=1、StructurePlacement=2、SpawnPoint=3 failures。
- 历史真实局存在 `runner_rc=3221225477`（0xC0000005，Python runner）；同轮游戏驱动记 `game_rc=0`，不能由此称 Godot 崩溃。attach 脚本只有发现 runner 尚存活才 taskkill 并记 runner_killed，R10 未记该字段；需继续核对原生依赖/自然异常/其他终止，不得直接略过。
- `r10-newdll/sample-020.json` 最后有效采样含 7 辆携带 400A 的矿车（代码类型 worker），余额 A=150，没有 `ore_refinery`；R9 也有同类结果。这些是**历史运行**，本轮未开新 Match。
- 源码/当前函数探针确认：只含 worker 的观测即 `economy_ignited=True`，512m 地图 desired recon=2；首座矿场分支已有 vehicle_factory 时 first_economy=False。这些判断不足以证明真实经济稳定。
- 移动独立反例：x=0 和 x=24 两单位 sight=4，`safe_relay_point([[0,0],[24,0]], ..., unit='mover', origin=[0,0])` 返回 `[24,0]`，穿过 (4,20) 盲区。说明端点/二分不能保证连续前缀。仅为独立纯数据复现，未宣称游戏运行结果。
- 原修复任务没有 5 FPS 视频，不能宣称动态通行通过。
- 共享源码 `rules_fallback.py` 在复核中出现新写入（21:37:33），本轮证据保存后续版本 hash；提示词要求执行前重新读当前版本，禁止覆盖其他任务。C# DLL 已保存 hash，不在文档任务重编译。

## 地图 UI 静态核对

- `MapGeneration.gd` 已定义五阶段：`g1_input`、`g2_terrain`、`g3_content`、`g4_scene`、`engine`。
- `ProgressBanner` 目前只显示阶段/详情文字；右侧阶段列表显示状态。提示词要求把真实 job/stages/progress 合并成中心总流程图，并保持右侧同源。
- 已实际打开用户截图：[map-progress-reference.png](../../runs/20261011-adjutant-map-review/map-progress-reference.png)。中心写 G1 已就绪而右侧 G2 正在生成；地图预览和历史卡片仍可见。红框是标注，只用于确定 UI 插入位置。
- 地图后端 `pipeline.py` / `server.py` 已有阶段记录、失败、跳过、布局重试和 progress 回调；提示词要求在缺字段时补充，禁止 UI 猜测完成百分比。

## 交付判断

提示词和计划已写入主工程 `agent/` 目录，可直接交给 DeepSeek。由于本轮是文档生成，未运行 UI/Match；后续 DeepSeek 实施必须按照提示词的分阶段真实 Match、截图、5 FPS 回看、回归和独立复核门禁推进。当前产品改动仍为 `needs-review`，本轮没有产品 candidate/champion 晋级；未开始新的迭代，连续未提升轮数不适用。

本轮仅使用指定 Python 环境做轻量验证，未结束现有 Godot/Python/Ollama。初始 PowerShell 7 出现内存不足/页面文件容量错误，换用可正常运行的轻量读文件方式；未基于此启动高负载新局，也未把环境错误归为游戏故障。
