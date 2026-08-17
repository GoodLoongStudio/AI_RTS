# AI 训练数据与 Benchmark 规范 P0/P1

> 文档状态：P0/P1 实施规格  
> 依赖：`AI副官_下一阶段开发训练与评测规格.md`  
> 首个场景：`单人战役_回声撤离_AI纵向切片验收表.md`  
> 原则：同一份受限 Observation / Intent 合同贯穿运行、采集、训练和评测。

---

# 0. 目标

建立一套不会随着模型、Provider、地图或 Prompt 变化就失效的 AI 数据基础设施。

需要同时解决：

1. 怎么记录一局；
2. 怎么从一局提取训练样本；
3. 怎么避免隐藏真值泄漏到训练输入；
4. 怎么区分游戏版本、场景版本和模型版本；
5. 怎么固定 Benchmark；
6. 怎么比较 Scripted / LLM / LocalModel / Candidate；
7. 怎么做回归，而不是只看几局“感觉不错”。

---

# 1. 数据分层

数据至少分三层，禁止混成一份 JSON。

## 1.1 Runtime Trace

完整运行追踪。

用途：

- 调试；
- 回放；
- 评测；
- 训练数据生成源。

Runtime Trace 可以包含内部 Result Ref 和 Evaluator 所需真值引用，但必须标记数据通道。

## 1.2 Policy Dataset

真正用于训练 Policy 的数据。

**输入只能来自正式 Policy Channel。**

不能因为 Runtime Trace 有完整世界状态，就把完整状态直接拷贝进训练样本。

## 1.3 Evaluation Result

从一批 Episode 汇总出的结果。

用途：

- baseline；
- candidate 比较；
- CI 回归；
- 训练 checkpoint 选择；
- 成本 / 延迟比较。

---

# 2. 版本身份

任何一局如果无法回答“这是哪一版游戏、哪一版场景、哪一版模型跑出来的”，就不能进入正式 Benchmark。

每个 Episode 至少记录：

```text
episode_id
started_at
repo_commit_sha
engine_id
engine_version
scenario_id
scenario_version
map_id
map_version_or_content_hash
seed
difficulty
observation_schema_version
intent_schema_version
feedback_schema_version
policy_id
policy_type
policy_version
provider_id
model_id
model_revision
prompt_version
tool_schema_version
runtime_profile
```

没有模型的字段允许为空，但键的语义应稳定。

---

# 3. Episode Trace 结构

建议逻辑结构：

```text
EpisodeTrace
├── metadata
├── initial_public_context
├── steps[]
├── domain_result_summary
├── evaluation
└── terminal
```

## 3.1 Step

每个 AI 决策 Step 至少包含：

```text
step_id
decision_tick
observation_id
observation_schema_version
observation_hash
policy_input_hash
proposed_intents[]
validation_results[]
accepted_intents[]
applied_tick
visible_feedback[]
fallback
latency_ms
token_usage
provider_request_id_optional
```

如果为了调试保存 Observation 正文，需要明确：

```text
channel = policy_visible
```

裁判真值必须放在独立命名空间，例如：

```text
evaluator_truth_ref
```

禁止两者结构相似到容易误用。

---

# 4. 训练样本类型

P1 先支持三类，足以开展第一轮模仿学习。

## 4.1 Single-step Decision

```text
Observation_t
→ Intent_t
```

适合：

- 合法动作学习；
- 简单目标选择；
- 小模型行为克隆；
- Tool Calling / JSON 输出微调。

## 4.2 Short-horizon Decision

```text
RecentVisibleHistory + Observation_t
→ Intent_t
```

适合：

- 撤退时机；
- 记忆旧情报；
- 连续计划；
- “不追击”等约束维持。

History 只能包含当时合法可见的历史。

## 4.3 Plan + Execution

```text
Observation
→ Plan / Goal Decomposition
→ Intent Sequence
→ Visible Result
```

P1 可以先记录，P2 再用于更复杂的层级训练。

---

# 5. 样本来源标签

每条样本必须带 `source_type`。

至少支持：

- `human`；
- `scripted_policy`；
- `teacher_llm`；
- `local_teacher`；
- `self_play`；
- `curated`；
- `synthetic`。

同时记录：

```text
source_policy_id
source_policy_version
source_episode_id
quality_label
accepted_by_validator
outcome_context
```

不能把“模型自己生成但最终非法”的 Intent 当作和高质量人工轨迹同等级数据。

---

# 6. 数据质量标签

P1 推荐至少：

## VALID

- Schema 合法；
- Validator 接受；
- 没有检测到权限泄漏。

## INVALID_ACTION

- Policy 输出可解析；
- 但命令被规则拒绝。

可以用于训练“不要这么做”，但不能直接混入正样本。

## PARSE_FAILURE

模型输出无法转换成 Intent。

主要用于工程诊断，不作为标准行为克隆正样本。

## TIMEOUT

没有在 deadline 前得到可用结果。

## LEAKAGE_SUSPECT

检测到输入 / 输出疑似使用不该知道的信息。

该样本默认禁止进入训练集，必须人工或自动复核。

## CURATED_GOOD

人工 / 规则筛选后的高质量示范。

后续可以继续增加战术质量分级，但 P1 不需要过度复杂。

---

# 7. Dataset 导出格式

底层具体使用 JSONL / Parquet 由程序根据工具链决定；策划只冻结逻辑字段。

建议一个训练样本至少能表达：

```json
{
  "dataset_schema_version": "...",
  "sample_id": "...",
  "episode_id": "...",
  "step_id": "...",
  "scenario_id": "...",
  "scenario_version": "...",
  "seed": "...",
  "repo_commit_sha": "...",
  "source_type": "...",
  "quality_label": "...",
  "observation_schema_version": "...",
  "intent_schema_version": "...",
  "policy_visible_input": {},
  "target_intent": {},
  "visible_result": {},
  "metadata": {}
}
```

上面是逻辑示例，不要求字段类型按示例原样实现。

关键要求只有一条：

> `policy_visible_input` 必须能证明来自正式受限观察，而不是从裁判真值重新拼出来的“更方便训练版本”。

---

# 8. Train / Validation / Test 切分

RTS 很容易发生数据泄漏。

如果同一地图、同一 Seed 的相邻轨迹随机切到 train 和 test，测试分数没有意义。

## 8.1 P1 最低切分原则

至少按以下一个或多个维度做 group split：

- Seed；
- Scenario 变体；
- 地图布局；
- 敌军部署；
- 任务参数。

禁止逐 Step 随机打散后切分。

## 8.2 推荐层级

### Train

允许见到主要机制和大多数参数组合。

### Validation

同机制，但保留部分 Seed / 部署 /参数组合。

### Test

至少保留：

- 未训练 Seed；
- 未训练敌军部署；
- 少量未训练组合；
- 固定永不进入训练的 Golden Benchmark。

---

# 9. Benchmark Manifest

Benchmark 必须是一个版本化清单，不是“大家记得去跑这几张图”。

逻辑结构建议：

```text
benchmark_id
benchmark_version
required_repo_range_or_schema
cases[]
  scenario_id
  scenario_version
  map_id
  seed
  difficulty
  opponent_policy
  timeout_profile
  control_mode
  repeats_optional
metrics[]
gates[]
```

## 9.1 第一批 Benchmark 分组

### B0｜协议正确性

小、快、确定性强。

覆盖：

- Observation Schema；
- Intent Schema；
- 权限；
- 隐藏信息；
- 错误侧信道；
- timeout；
- stale decision；
- deterministic replay。

适合进入 CI。

### B1｜单能力战术

小地图 / 短回合。

覆盖：

- Move；
- Scout；
- Hold + no_chase；
- Attack / Focus；
- Retreat；
- UseAbility；
- 玩家接管。

### B2｜《回声撤离》P0

首个端到端 Benchmark。

覆盖：

- 任务阶段；
- 剧情情报；
- 多小队；
- 权限；
- 撤离确认；
- Trace。

### B3｜后续综合 RTS

等生产、经济、科技等系统稳定后再加入。

---

# 10. Metrics 统一命名原则

不要让每个评测脚本发明不同指标名。

建议分命名空间。

## protocol.*

例如：

```text
protocol.schema_parse_rate
protocol.hidden_leak_count
protocol.invalid_intent_rate
protocol.stale_decision_reject_rate
protocol.replay_match
```

## gameplay.*

例如：

```text
gameplay.mission_complete
gameplay.objective_progress
gameplay.completion_tick
gameplay.unit_value_lost
gameplay.trade_efficiency
gameplay.critical_survival
```

## intel.*

例如：

```text
intel.refresh_count
intel.operation_points_spent
intel.remembered_used
intel.scout_coverage
```

## runtime.*

例如：

```text
runtime.decision_latency_p50
runtime.decision_latency_p95
runtime.timeout_rate
runtime.fallback_rate
runtime.parse_failure_rate
runtime.tokens_in
runtime.tokens_out
runtime.estimated_cost
```

具体实现可以映射到更合适的数据结构，但概念不要混淆。

---

# 11. Score 与 Gate 分开

一个模型可以综合得分更高，但仍然因为规则错误被禁止发布。

因此：

## Hard Gate

违反即失败：

- 隐藏信息泄漏；
- 控制未授权单位；
- Core 崩溃；
- Schema 不兼容；
- 无确定性 fallback；
- Golden protocol case 失败。

## Soft Score

用于模型强弱比较：

- 完成率；
- 时间；
- 损失；
- 资源效率；
- 决策质量；
- 延迟；
- 成本。

不要用一个加权总分掩盖 Hard Gate。

---

# 12. Baseline 与 Candidate 比较

每次正式 AI 改动至少记录：

```text
baseline_policy
candidate_policy
benchmark_version
repo_commit_sha
case_count
seed_set
metric_delta
hard_gate_result
```

比较规则：

1. 同一 Benchmark；
2. 同一场景版本；
3. 同一 Seed 集；
4. 同一权限 / 操作点规则；
5. Provider 模型比较时记录 Prompt Version；
6. 游戏规则变化后重新建立 baseline，不能沿用旧分数硬比。

---

# 13. 第一阶段不要提前锁死的数值

当前先建设采集与统计，不提前拍脑袋锁：

- “任务完成率 ≥ 80%”；
- “非法命令 < 2%”；
- “p95 必须 < 某毫秒”；
- “成本必须 < 某美元”。

正确流程：

```text
Scripted baseline
→ 收集分布
→ Remote LLM baseline
→ 收集分布
→ 确定可接受阈值
→ 锁 Benchmark version
→ 才进入回归 Gate
```

协议正确性类 Hard Gate 可以从第一天就锁死。

---

# 14. 模仿学习第一批数据建议

P1 第一批数据不追求海量，先追求“合同正确”。

优先采集：

## D1｜Move / Scout

- 不同起点；
- 不同合法观察范围；
- 简单障碍；
- 目标区域。

## D2｜Hold + No Chase

- 敌人接近 / 远离；
- 有无高价值目标诱导；
- 不同防区大小。

## D3｜Retreat

- 不同损失程度；
- 安全点变化；
- 有限情报。

## D4｜Focus Target

- 多目标类型；
- 目标失去视野；
- 旧情报过期。

## D5｜Echo Extraction

- 从 ScriptedPolicy 和人工轨迹采集完整 Episode；
- 保留阶段信息用于 evaluator；
- Policy 输入仍严格受限。

---

# 15. Teacher LLM 数据生成规则

后续使用更强模型做 Teacher 时，必须经过正式链路：

```text
Policy Observation
→ Teacher
→ ProposedIntent
→ Validator
→ Core / Scenario
→ Result
→ Quality Filter
→ Dataset
```

禁止：

```text
完整真值
→ Teacher 生成“完美答案”
→ 当成正式 Policy 训练数据
```

除非明确把这类数据定义为“Privileged Distillation Research”，并和正式可部署 Policy 数据完全隔离。

P1 默认不做这种特权蒸馏。

---

# 16. Self-play 数据规则

P2 才启用。

Self-play 每局必须记录双方：

- policy id/version；
- 权限；
- observation schema；
- seed；
- opponent identity；
- reward components。

训练时避免只和同一 checkpoint 循环自博弈，后续需要：

- opponent pool；
- frozen checkpoints；
- scripted anchors；
- 防止策略退化的 Golden Benchmark。

这不是 P0/P1 前置实现。

---

# 17. CI 与离线 Benchmark 分层

## CI Fast Suite

每次关键提交可以运行：

- B0 协议；
- 少量 B1；
- 极简 Echo Smoke Test。

要求：

- 快；
- 无外部模型依赖；
- 主要使用 Mock / ScriptedPolicy；
- 固定 Seed。

## Offline / Manual Benchmark

用于：

- Remote LLM；
- LocalModel；
- 多 Seed；
- 成本统计；
- Candidate 比较。

外部 Provider 波动不能让普通 Core CI 变红。

---

# 18. 程序开发任务建议

## DATA-001｜EpisodeTrace Writer

能够从 Headless 和正常游戏写同一逻辑 Trace。

## DATA-002｜Policy-safe Exporter

只从 Policy Channel 生成训练输入，并提供自动检查防止 Evaluator Truth 混入。

## DATA-003｜Dataset Manifest

记录数据集版本、来源、Schema、场景范围、样本数、切分方法。

## BENCH-001｜Benchmark Manifest Loader

按 manifest 批量运行 Scenario + Seed + Policy。

## BENCH-002｜Metric Collector

统一采集 protocol / gameplay / intel / runtime 指标。

## BENCH-003｜Baseline Compare

输出 baseline vs candidate delta 和 Hard Gate。

## BENCH-004｜Machine-readable Result

至少输出一种结构化格式供 CI / 后续 Dashboard 使用。

---

# 19. P0/P1 Definition of Done

## P0

- [ ] Episode 能记录 repo SHA / scenario / seed / policy；
- [ ] 每个 Decision Step 可追溯 Observation → Intent → Validation → Result；
- [ ] Evaluator Truth 与 Policy Visible 数据有明确隔离；
- [ ] ScriptedPolicy 可以跑固定 Benchmark；
- [ ] B0 协议测试可以自动执行；
- [ ] 《回声撤离》能输出结构化评测结果。

## P1

- [ ] Trace 可导出 Policy Dataset；
- [ ] 数据集有 Manifest；
- [ ] 训练 / 验证 / 测试按组切分，不逐 Step 随机泄漏；
- [ ] Remote LLM / LocalModel 使用同一 Benchmark；
- [ ] 结果可比较 baseline / candidate；
- [ ] Prompt / Provider / Model 版本进入评测身份；
- [ ] Hard Gate 与 Soft Score 分离；
- [ ] 第一个模仿学习实验可以只依赖正式可见输入完成。
