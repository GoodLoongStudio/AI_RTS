# AI 副官（单模型高效指挥）迭代记录

> 依据 `docs/程序文档/AI副官_单模型高效指挥_计划与DeepSeek执行提示词_2026-09-11.md` 与
> `AI副官_单模型高效指挥_技术实现设计_2026-09-11.md` 执行。
> 每条记录固定格式：**观察到的问题 → 具体机制 → 一项主要修改 → 固定条件对照结果 → 下一步**。
> 未达标的数字照实写，不做美化；外部案例的成绩不作为本项目证据。

执行者：DeepSeekV4.1FLASH（CodeBuddy）。开始时间：2026-09-12。

---

## 冻结条件（所有对照数字都在此条件下取得）

| 项 | 值 |
|---|---|
| 模型 | `minicpm5-adj-16k:latest`（Ollama，2.5B，Q8_0，ctx 16384，全量驻显存；派生标签，基础模型 `maternion/minicpm5:2b`） |
| 端点 | `http://127.0.0.1:11434/v1`（本机 Ollama，下发 `reasoning_effort=none`） |
| 硬件 | RTX 3080 Ti 12GB（与游戏同机；A/B 期间游戏进程保留运行） |
| 观测数据 | `source/adjutant_coordinator/tests/data/observations/real_20260912.jsonl`（60 条，Player_0 小编制 4 单位）、`real_mass_20260912.jsonl`（60 条，Player_1 大编制 19→25 单位） |
| 采集方式 | `python -m adjutant_coordinator.deploy.capture_observations --with-ai --keep-running`（**只读** `op=status/rules/tactical/strategic`，不碰玩家相机、不下命令） |
| A/B 工具 | `python -m adjutant_coordinator.deploy.format_ab_test --mode both`（单次原始调用，无重试；token 取响应 `usage`） |
| 结果文件 | `source/adjutant_coordinator/logs/format_ab_fast_20260912.json`（首轮失败）、`format_ab_fast_20260912b.json`、`format_ab_deep_20260912.json`、`format_ab_both_20260912.json`（最终） |

---

## 第 1 轮（阶段 A）：四列短决策接口 vs 旧格式

### 观察到的问题
旧 `DirectiveBatch` 链路在真实观测上：输入 **4350 token**、P95 **4.11s**，而计划目标为
fast P95 ≤1.5s、deep P95 ≤3s；输出 99~388 token（同一模型常回填大量可照抄字段）。

### 具体机制
1. 旧上下文把每个实体的 `entity_id/pos`、`productions/constructions` 的笛卡尔积、
   40 余项候选全量塞进 JSON 对象数组，键名重复 → 输入膨胀；
2. 旧输出要求模型写 `action/units/target_id/target_pos/producer/scene/task_id`，
   多字段枚举 → 输出膨胀并给出可照抄模板。

### 主要修改（新增，不替换旧路径，便于 A/B 与回退）
- `graph/task_patch.py`：四列契约 `TaskPatchBatch`（`{"u":[[actor,skill,target,params]]}`）、
  技能词表（ATK/DEF/RET/SCT/GRP/GAT/BLD/PROD/MOVE/HOLD/STOP）、参数档（P0~P6、Q1~Q8）、
  `DecisionFrame`（不可变请求视图：引用表 + 逐对象代际 + 本地接收期限）、
  逐行逐列解码（能力/目标类别/参数相容性）、**每执行者一行**、行上限；
- `graph/squads.py`：观测 → 稳定执行者表（S* 作战小队 / W* 工人组 / F* 生产设施，
  按集群+类型确定性派生，可注入权威小队表）、目标表（E*/R*/B*/L*/U*/V*，点位带中文语义标签）、
  建造落点候选（程序算，模型不猜坐标）；
- `deploy/capture_observations.py`：真实观测只读采集（本轮的 120 条数据来源）；
- `deploy/format_ab_test.py`：旧/新格式 A/B（首次结构合法率、语义合法率、token、延迟、
  多执行者覆盖、冷启动）。

### 固定条件对照结果
首轮（120 条，fast）：old 语义 98.0%、P50 1.20s / P95 4.11s、in 4350；
**new 语义仅 54.4%**（空批次 0，多执行者 55/120）。逐行拒绝分布：
`capability_mismatch 139`、`duplicate_actor 66`、`skill_not_allowed_for_actor 14`。

### 根因与修复（同一轮内的连续迭代）
| 现象 | 机制 | 修复 | 复测 |
|---|---|---|---|
| 新格式回 `{"u":[]}`（4/4 空） | 提示词只给"选表"规则，**没给单步职责规则**；`P0=维持现状` 让"什么都不做"成了默认答案 | 补"按顺序派活"的单步规则（采集→生产→建造→交战→侦察） | 空批次 0 |
| 输入 1985 token（超 1024 预算） | JSON 对象数组键名重复、参数档 15 条、每设施重复 6 个建筑名 | 改**紧凑文本表**（一行一类，ref 自带类别语义） | 918 token（fast）/ 953（deep） |
| `capability_mismatch` 139 | 要求 2B 做"设施→合法产品"两步配对；仓库记忆早记过"给 2B 的规则要单步比较" | 程序把配对**预先写进表**：`生产设施: F1只能造U4(tank)` | 0 次 |
| `skill_not_allowed_for_actor`（`F1,BLD,V4`，8/8 条） | 模型把"生产建筑"当建造者 | 加**建造候选**预配对：`W1造V4(barracks)`，提示词给出整条示例行 | 0 次 |
| `duplicate_actor` 66 | 模型用 4 行给同一工人组派 4 个资源 | 解码层**每执行者一行**（权威任务表本就"每个执行者一条当前任务"）+ 行上限=min(模式容量, 执行者数) | 3 次（fast） |
| deep 语义 78.4% < fast 97.6% | deep 容量 10 行、观测只有 3 个执行者 → 模型**凑行数**重复同一执行者 | 行上限 = min(模式容量, 执行者数)，并把该数量写进提示词 | 99.0% |
| 结构合法率 0%（内容正确） | 模型回 ```json 围栏 | 提示词禁围栏 + 解析容错（记录"严格"与"归一化后"两个口径） | 100%/100% |

### 最终对照结果（120 条真实观测，同一模型、同一数据、同一时段）

| 指标 | fast-old | fast-new | deep-new | 计划目标 |
|---|---|---|---|---|
| 首次结构合法率（严格 / 归一化） | 100% / 100% | **100% / 100%** | **100% / 100%** | 结构合法率 ≥99% |
| 语义合法率 | 98.0% | **99.8%** | **99.0%** | ≥95% |
| 延迟 P50 / P95 | 1.20s / 4.11s | **0.55s / 0.83s** | **0.57s / 0.91s** | fast ≤1s/≤1.5s；deep ≤2s/≤3s |
| 输入 token P50（max） | 4350 | **918（951）** | **953（1006）** | fast ~1024；deep ~2048 |
| 输出 token P50（max） | 99（388） | **54（78）** | **54（114）** | fast ≤96；deep ≤256 |
| 截断 / 错误 | 0 / 0 | **0 / 0** | **0 / 0** | 截断率参与容量判定 |
| 一次输出多个不同执行者 | 120/120 | **120/120** | **118/120** | 必须能同时派多个执行者 |
| 冷启动首轮 | 0.72s | 0.32s | 0.44s | 冷启动单列 |

### 容量修订（有证据，非静默变更）
计划初始容量 fast 4 行 / deep 8 行。实测 2B 在 8 执行者观测上稳定输出 5~7 行，
**输出仅 90 token（≤96 预算）、无截断**；按 4 行硬卡把合法任务判成容量超限，
语义合法率被压到 54%。故按计划"实际 token 与截断率决定能否使用该容量"改为
**fast 6 行 / deep 10 行**，并加"行上限 ≤ 执行者数"约束。

### 未解决问题（照实记录）
- deep 仍有 6 行 `duplicate_actor`（模型偶发重复同一执行者）；fast 有 1 行
  `W4,PROD`（工人组被派生产）。二者合计 <1% 行，已被解码层安全拒绝，不执行。
- 本轮的延迟是**模型调用耗时**，不含排队、权威提交与单位实际进入新任务；
  计划 §7.A 明确此阶段"隔离模型接口，不把回放结果当成真实游戏端到端结果"，
  端到端响应测量留在阶段 C（有界异步调度 + 真实对局）。
- 观测覆盖：经济/生产/侦察/有限交战（可见敌人 1~5）；**玩家介入**场景尚未采集到真实样本
  （需要玩家手动接管的观测），列为下一批采集项。
- 采集时己方编制较小（Player_0 4 单位），多小队覆盖依赖 Player_1 视角的 19~25 单位观测；
  阶段 C 的规模测试要用 100/200/300 单位观测补足。

### 下一步（立即执行）
阶段 A-2：把四列接口接入运行时——`TaskPatchBatch` → 程序展开为任务表修改 →
复用既有权威链（`adjutant_intent`）逐项校验与回执；`StrategicPlan` 不再是下令前置条件。
入口文件：`graph/pydantic_agents.py`（新增四列 Agent）、`graph/nodes.py`（`node_tactical_agent`）、
`deploy/agent_runner.py`（runner 开关与模式）。

---

## 第 2 轮（阶段 A-2）：四列接口接入运行时

### 主要修改
- `graph/task_patch_prompt.py`（新）：**唯一**提示词实现（常量系统提示 + 紧凑输入表 +
  输出归一化）；A/B 工具改为引用它，消除"评测提示词 vs 生产提示词"漂移
  （机械重构脚本执行后已删除，工具冒烟复测语义仍 100%）。
- `graph/task_patch_bridge.py`（新）：`frame_from_state`（所有元数据取自**发起请求时**的
  状态/观测）、`expand_patch`（四列 → `IntentBatch`）、`summarize_decode`（逐项接受/拒绝留痕）。
- `graph/pydantic_agents.py`：新增 `PydanticAITaskPatchAgent`（`output_type=TaskPatchBatch`、
  输出上限按模式 96/256、`propose_task_patch(frame)`）；基类抽出 `_max_tokens()` 与
  `_run_text()`（四列输入是紧凑文本而非 JSON）；新增 `last_raw_text` 供诊断围栏/截断。
- `graph/nodes.py`：`node_tactical_agent` 检测 `propose_task_patch` 后走新路径
  `_tactical_via_task_patch`；**旧路径原样保留**（A/B 与显式回退）。
  关键边界：模型成功时程序**不再补任何它没选的战略任务**（旧发展阶梯退到只在降级路径生效），
  以符合"不得形成两个互相抢控制权的指挥中心"。
- `deploy/agent_runner.py`：新增 `--interface four-col|legacy`（默认 four-col）与
  `--tactics-mode fast|deep`；`MeteredModel` 透传 `propose_task_patch/mode/last_decode`。

### 验证
- 新增 `tests/test_tactical_task_patch.py`（5 用例，全绿）：新路径确实被调用、决策留痕标注
  `interface=task_patch`、模型成功时无程序侧扩张、模型失败→明确标记规则兜底且保留 degraded_reason、
  解码摘要可审计（accepted/rejected/reject_reasons）。
- 全量单测：`python -m unittest discover -s adjutant_coordinator/tests`（cwd=`source/`，
  `PYTHONPATH=source`）→ **365 tests OK**（含既有 224 基线，无回归）。
  注意：在 `adjutant_coordinator/` 目录下跑 discover 会让 `test_behavior_tree` 报
  `No module named 'adjutant_coordinator'`（该文件未自插 `source` 路径）——这是运行目录问题，
  不是本轮改动引起。
- CLI/装配核验：`--interface {four-col,legacy}`、`--tactics-mode {fast,deep}` 生效；
  `PydanticAITaskPatchAgent` fast→96 token / deep→256 token，缺省为 fast。

### 未解决问题（照实记录）
- 尚未做**真实对局端到端**验证：新接口在真机上的"事件进入 → 相关单位实际进入新任务"时延
  仍待阶段 C 测量（本轮只证明接线与单测通过）。
- 任务表还在程序侧派生（`graph/squads.py`），**游戏权威端的小队表与任务生命周期（ATK/DEF/RET/
  SCT/GATHER/BUILD/PROD 的完成/失败/中止）尚未实现**（阶段 B）。
- 单一在途异步调度、优先级队列、过期结果拒绝、单调时钟失败退避仍是旧实现（阶段 C）。
- 旧的 `propose_intents` 路径与其规则兜底仍存在：模型成功时已不参与，但降级时仍会补任务，
  需要在阶段 C/B 明确"降级只做保守动作"的清单，避免规则悄悄改变战略。

## 第 3 轮（真实对局闭环：权威端复核 + 发展链真凶）

### 假设
"命令没落地"与"钱多不发展"都是程序侧缺陷，不是模型能力问题。

### 证据与修改
1. **查错端口**：`24570` 是客户端（`is_server=False`，账本永远 `PendingAuthority`）；
   **真权威是 `24572`**（`Accepted 4 / Rejected 2 / ProducerNotConstructed 44`）。
   runner 的 `--authority-port` 是唯一端口（下发/观测/复核），改指 **24572** 后立刻读到权威终态。
2. **生产链路从未把余额渲染给模型** → `frame.balance` + 每件造价进输入表。
3. **建造落点太挤**（12m 一圈 4 点，建筑挤在 CC 5m 内把工人堵在 1.5m 口袋）
   → 两圈 16 槽 + `occupied_points`，落点按**净空最大**挑。
4. **未完工工地没人管**（`vehicle_factory constructed=False`）→ 阶梯 1 只判类型存在、
   阶梯 2 按类型派生产 → 权威端 **38 次 `ProducerNotConstructed`**。
   修：`constructed` 三态进 `_normalized_units`；`ladder_inputs` 增
   `unfinished_buildings/constructed_producers`；新增**阶梯 1.5（未完工工地优先建完）**；
   阶梯 2 只派已完工设施。
5. **进度误判失败** → 释放单位 → 重发（47/50 条被标 failed）→ 改判 `unknown`（继续占用）。
6. **游戏侧幂等账本无淘汰** → 永久 `LedgerFull`（273/275 被拒）→ 加 `_adjutant_ledger_evict_one`。
7. **候选菜单**（计划 §二/§七§3 硬门槛）→ 发展候选 2~3 条 + 「维持现有任务」，
   删掉 6 步自然语言政策，生产数量提示 Q4~Q8 → **Q2**（不占满队列）。

### 测试条件与结果
- 单测：`unittest discover -s adjutant_coordinator/tests` → **404 OK**。
- 真实对局（24572 权威）：坦克刷屏消失，改为 `rule-build-finish-Unit_6|build`；
  10 秒复检重复率 0%；余额 55350 持续上升（采集有效）。

### 剩余问题（已写入阻塞报告）
- **A**：`rule-build-finish-Unit_6|build` 被权威端 `Rejected` ×32，且 `op=commands`
  未暴露 build 类 `primary_issue/issues`（需游戏侧补字段或指定可读的 op）。
- **B**：旧 checkpoint 的在途意图仍在每轮下发（"旧结果复活"）→ 需下发前按当前观测预校验
  （未完工设施不派生产）。
- **C**：2B 仍可能只回 gather，不按候选菜单发展 → 需候选排序 / 信息范围 / §四 微调。

### 下一步（立即执行）
先解 A（暴露 build 拒绝详情），再解 B（下发前预校验 + 旧意图失效），随后端到端时延与规模测试。

## 附：阶段 C 原始待办（调度与闭环）
阶段 C 的**调度与闭环**（先解决计划点名的阻塞）：把 `pydantic_agents` 的
`future.result(timeout=…)` 同步等待替换为真正异步调用；实现单一在途工作槽 + 有界队列 +
普通观测合并 + 紧急优先 + 过期结果拒绝 + 单调时钟失败退避；随后在真实对局里跑
`--interface four-col` 验证端到端时延与"命令真的落到单位"。

---

## 第 3 轮（阶段 C 接手）：图侧三处饿死点修复 + Q1 干净测速 + 5 分钟真机验收

执行者：ZCode（GLM-5.3Flash，电脑控制会话）。时间：2026-09-12 12:30~14:10。
接手自《AI副官_交接提示词_2026-09-12》，按协同提示词分工负责图与游戏侧
（nodes/runtime/graph/state/interrupts + Godot 侧阶段 B）。

### Q1：干净条件下模型真实速度（交接要求的第一条验收）

固定条件：`ollama ps` = `minicpm5-adj-16k 100% GPU`、单 llama-server 实例（3356MB）；
探针 `tmp_logs/langgraph_recon/q1_clean_speed_probe.py`（生产提示词 + temperature 0 +
显式 ProxyHandler({})），同一条真实观测连测 5 次：

| 条件 | own 单位 | in tokens | P50 | P95 | max |
|---|---|---|---|---|---|
| 无游戏、无 runner | 4 | 810 | **0.44s** | 0.46s | 0.46s |
| 无游戏、无 runner | 25 | 965 | **0.78s** | 0.79s | 0.79s |
| **对局运行中**（游戏占 GPU）、无 runner | 25 | 965 | **0.61s** | 0.63s | 0.63s |

**结论：模型不是瓶颈**（对比交接记录里"服务端 3.5~4.4s"）。Q2 的三个选项
（压输入 / 限帧 / 换模型）**均不需要**——真机慢的真因在图侧，见下。

### 观察到的问题：真机对局 556/556 全 strategic、0 提交、own=4 全程不变

修复后的 runner（无空壳模型）在真机上反而完全不动：路由恒 strategic、
`task_patch_submitted=0`、`sent=0`、5 分钟资金 50000 纹丝不动。
规则微操每 tick "添加意图"（`micro_control_added`）但同样 0 下发。

### 具体机制（三个叠加的饿死点，全部实证）

1. **路由死锁**：`--strategy-mode off` → `active_plan` 恒 None → `is_strategy_due` 恒真
   → 路由永远 strategic；战略层关闭后不再报错（也就不进冷却让位）→ 战术节点
   （唯一会提交 task_patch 的地方）永远轮不到。以前是靠"空壳模型反复报错→冷却→让位"
   把路由挤进战术的，修好空壳 bug 后死锁暴露。
2. **LangGraph 通道漏声明**：`GraphStateDict` 只声明部分状态键，LangGraph 在图入口
   `_cleaned()` 与节点输出两处把未声明键**静默过滤**。`strategy_disabled`（路由守卫）
   与 `patch_ready`（异步结果收取）都不在声明里 → 标志立不住、结果收得到却落不了地
   （实测 63s 内 1 次提交被"应用"33 次 = 通道旧值反复重放）。
3. **node_wait 清空微操候选**：非战术轮的微操候选在 `node_classify` 加入、经
   WAIT→ARBITRATE 边送仲裁，但 `node_wait` 无条件 `candidate_intents=[]`，
   全部饿死（仲裁 accepted/dropped 恒空、整局 sent=0）。且行为树会在 wait 轮
   顶掉模型仍在执行的任务（replay_base_attack tick6：bt-attack 盖掉 attack_move 回防）。

### 主要修改（全部在我负责的文件内）

| 文件 | 修改 |
|---|---|
| `graph/state.py` | 新增 `strategy_disabled` 字段 + to_dict/from_dict 序列化 |
| `graph/interrupts.py` | `classify_route` 战略分支加 `strategy_disabled` 守卫 |
| `graph/runtime.py` | 构造期按实际战略模型立标志；`restore()` 后重申（checkpoint 可能来自旧会话） |
| `graph/nodes.py` | ① `node_strategic_agent` skip 分支立标志；② `_intake_patch_outcome` 每轮先重置 `patch_ready`（同 tick 交接键，禁跨 tick 残留）；③ `_tactical_via_task_patch` pop 后显式清空；④ `node_wait` **不再清** `candidate_intents`；⑤ `_run_micro_layer` 加**活跃意图守卫**（行为树不顶活跃任务、阶梯只顶更低优先、retreat 永远放行）；⑥ `_StateView` 补 `live_intents()` |
| `graph/graph.py` | `GraphStateDict` 补声明 `strategy_disabled / patch_ready / plan_version_history / reserves* / task_progress`（漏声明的键在 langgraph 引擎下被静默丢弃） |
| `tmp_logs/langgraph_recon/{attach_runner_fourcol26,restart_demo_adjutant_async_noai,start_demo_noai_norunner}.py` | 修 PowerShell 杀进程谓词（旧写法 `Name='python.exe' -and ...` 被 PS 当命令解析、静默杀不到 → 实测两个 runner 并存抢同一权威端口）；attach 加杀后复查 |

单测 380 → **388 OK**（新增 8 个回归钉：路由守卫×4、langgraph 通道×2、
wait 保留候选×1、结果单次应用×1）；与协同方改动合并后 **389 OK**。

### 固定条件对照结果（修复后真机，无 AI、四列 + 异步、事件文件
`agent_runner_events_20260912_135847_75b79064.jsonl`）

| 指标 | 修复前（交接记录） | 修复后（本轮 5 分钟观测） |
|---|---|---|
| 路由分布 | strategic 556/556 | tactical 30 + wait 428（战术节拍 ~3.3s/次） |
| task_patch | submitted=0 | **submitted 15 = result 15 = applied 15，status 全部 ok，0 expired** |
| 模型耗时 | P50 4.2s / max 8s | **P50 328ms / P95 452ms**（fast 目标 ≤1s/≤1.5s） |
| 回执 | 0 | **Accepted 175 / PendingAuthority 94**（build/produce 走权威确认，符合设计） |
| 结果层 | own=4 全程不变 | **own 4→7：新增 barracks、vehicle_factory、soldier；资源账本 ledger 128；资金 50000→48750** |
| 主循环 | 被战略重试拖到 4.7s/轮 | graph_observation 458 次/5min ≈ 0.65s/轮（模型在途不阻塞） |

**诚实声明**：本局模型的四列输出全部为空批次（rows=0，即"维持现状"）——
基地经济（采集/集结/建造/生产）目前由行为树/规则微操驱动。协同方随后定位的根因
（声明式输出逼 2B 回空）及其修复见协同提示词 §5；合并后需要一局联合复验确认
`task_patch` 事件 `accepted>0`（模型真的派任务）。

### 回答协同方的核对问题

- **我没有整份覆盖过 `pydantic_agents.py`**，也没有 checkout/stash/restore 过任何文件。
  该文件我只读过（写探针脚本时参考其 `GraphModelSettings`）。你看到的 mtime 12:14 应为
  上一任（DeepSeek）会话的落盘时间，与本次会话无关。你们 14:04 的 structured_output 修复
  是我工作区里该文件的最新改动，无需与我合并。
- **披露**：读到协同提示词之前（约 13:40~13:55），我已按本轮机制分析改过
  `_intake_patch_outcome` 与 `_tactical_via_task_patch` 两段——内容是上文 ②③ 两处
  `patch_ready` 重置/清空（各 2~4 行，带注释）。你在 nodes.py 只加 `raw=` 字段
  （现于第 858 行，与我的改动并存、全量单测 389 OK），两边无冲突，无需返工。

### 协同与占用

- 已按协同纪律核查：14:07:47 起协同方（CodeBuddy）的对局 + 单一 runner 在跑
  （进程实况核实，非猜测）。我等待其登记 [已释放] 后，用独立 run_dir
  `local_run27_zcode` 做合并后联合复验（起局前先清 agent_runner 并复查）。
- 电脑控制（DCS 只读通道 + 窗口截图）已验证可用：HUD 显示"AI 副官：运行中/
  正在执行：采集、集结/下发 2 条（指挥 7 个单位）"，画面出现"副官：采集 2 个单位"
  指令可视化——与结构化日志互证。
