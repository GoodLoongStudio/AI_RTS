# 闭环验证报告：<任务名>

- 日期：<YYYY-MM-DD>
- 计划：`agent/plans/<plan>.md`
- 提示词：`agent/prompts/<prompt>.md`
- 运行目录：`agent/runs/<run-id>/`
- 状态：`complete` / `blocked` / `needs-review`

## 1. 目标与验收条件

## 2. 实施改动

| 文件 | 改动 | 权威口径/新值 |
|---|---|---|

## 3. 运行时实测

| 探针 | 结果 | 原始日志 |
|---|---|---|

## 4. 截图验收

| 截图 | 观察结论 |
|---|---|

## 5. 自动化验证

| 命令 | rc | marker/禁则 | 结论 |
|---|---:|---|---|

## 5.5 RSI 检查点决策（多轮任务必填）

- 当前阶段：
- candidate ref/tree hash：
- champion ref/tree hash：
- 硬门禁是否全过：
- 质量向量 before → candidate：
- 连续未提升轮数：
- 决策：`promote` / `reject` / `new-stage` / `needs-review`
- 证据：`agent/runs/<run-id>/round-NN/`

## 6. 独立复核

## 7. 未验证项与风险

## 8. 回滚方式
