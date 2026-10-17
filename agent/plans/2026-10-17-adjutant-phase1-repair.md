# 副官第一阶段第四轮返修计划 — 2026-10-17

目标：把第四轮独立复核确认的 E1–E4 缺陷修入实现，并完成可重复回归、真实 Match 与阶段复验。沿用现有 LangGraph、任务账本、权威回执和观测解析，不引入第二套任务权威。

## 范围

1. E1：把 `PendingAuthority` / `Unknown` 作为未结论状态；同一 `(attempt, intent, command)` 允许非终态推进到终态，终态重放只结算一次。
2. E2：恢复授权生成稳定 attempt identity；命令回执携带提交时捕获的 attempt identity；尝试之间不共享活动集合，晚到旧回执不污染当前尝试，并保留有限历史。
3. E3：从 `normalized_units` 的实体键正确填入 `own_constructed`，按指定工地做完整 facts→判据接线。
4. E4：类型完工计数只把权威明确报告 `constructed=True` 的实体算作已完工；`False` 与 `None`/缺字段保持不同语义，未知不提前通过。

明确不做：战略重构、经济链重写、模型替换、路径迁移、清理其他 dirty worktree、修改历史基线 / champion 文件或覆盖 `round-08` 四审产物。

## 执行顺序与门槛

- E1 → 解析 + E1 回归 → 新鲜无头真实 Match（真实 Match 场景、命令与 physics tick）→ 旧链路回归，通过才进入 E2。
- E2 → Python 解析 + 任务/图运行回归 → 新鲜无头真实 Match → 旧链路回归，通过才进入 E3。
- E3 → campaign/facts 回归 → 新鲜无头真实 Match → 旧里程碑链路回归，通过才进入 E4。
- E4 → campaign / task-loop 相关回归 → 新鲜无头真实 Match → 旧经济与建造链路回归。
- 最后重跑完整相关 Python 套件、独立正反探针，并按原任务运行 600 秒真实单人房观察；校验源码身份、PID、日志 mtime 和清理状态。
- 任一单补丁 S1 失败立即停下，先从该逻辑候选修正；不在坏候选上叠加下一个方向。全量回归 / 独立复核 / 清理门禁未齐时只记 `needs-review`，不得提升 champion。

## 共享工作区保护

工程：`G:/AIRTS/AI_RTS`；分支/HEAD 以本轮 baseline.json 为准。相关源码和测试含既有 dirty 内容，均按精确补丁编辑；禁止 reset、clean、checkout、切分支、批量覆盖或清理非本轮进程。复用已运行 Ollama `11434` 服务，不终止服务。所有新证据写入本计划专属运行目录。

## 初始门禁结果

- Git root：`G:/AIRTS/AI_RTS`，develop 根目标检查 rc=0。
- 修改目标逐项检查 rc=0；证据输出目录按 runs 既有约定仅作运行产物。
- 初始源码身份、mtime、相关 dirty 状态、既有 Godot / Ollama 进程见本轮 [baseline.json](../runs/2026-10-17-adjutant-phase1-repair/baseline.json)。
- 当前 champion 仍为 `4851de361b4c924cde0eacbe2d113b14fc6c9798+dirty`；旧候选 `cand-phase1-d-rework` 因第四轮复核状态为 needs-review。本轮使用独立候选记录，不覆写 champion。
