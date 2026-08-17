# AI 副官｜下一阶段开发、训练与评测规格

> 文档状态：P0 实施规格  
> 适用阶段：RTS Core 重构完成后 → 首个 AI 可玩纵向切片  
> 正式交付分支：`main`  
> 目标：把“AI 副官”从体验概念收敛为程序可实现、模型可接入、数据可训练、结果可评测的一套统一合同。

---

# 0. 本文档解决什么问题

当前项目已经具备三块重要基础：

1. 核心体验已经明确：玩家表达意图，AI 组织行动，玩家保留最终控制权；
2. RTS Core 已完成一轮重构，程序边界开始稳定；
3. AI 操作点与受限观察已经有独立程序方案，明确 Human / Rule AI / LLM 应共享权威命令服务，同时限制 AI 可见信息。

下一阶段不能直接跳到“接一个大模型看看效果”。如果先接模型、后补协议，最终会出现：

- 每种 AI 各自读取一套游戏数据；
- LLM 直接依赖 Godot Node 或 UI 临时结构；
- 训练时能看到的信息和正式游戏不同；
- 模型失败、超时、非法命令没有统一处理；
- 只看胜率，无法解释为什么模型变好或变差；
- 游戏规则一改，Prompt、训练数据、评测全部失效。

因此，从本阶段开始统一收敛为一条链：

```text
受限观察 Observation
        ↓
Agent / Policy
        ↓
结构化意图 Intent
        ↓
权限与规则校验 Validator
        ↓
权威 RTS Core
        ↓
内部结果 / 领域事件
        ↓
受限反馈 + Trace / Replay
```

**这条链同时服务：脚本 AI、LLM、本地模型、未来训练模型、自动化评测。**

本文档定义策划语义和实施顺序；底层程序边界仍以 `docs/程序文档/程序重构_AI操作点与受限观察方案.md` 为准，不在这里复制第二套架构。

---

# 1. 本阶段必须冻结的 7 个设计决定

## 1.1 AI 是“受权限约束的指挥代理”，不是外挂玩家

AI 副官不能因为程序接入方便而获得完整世界状态。

正式对局中，AI 只能看到它按规则获得的情报；训练和评测系统可以额外持有“裁判真值”，但裁判真值绝不能进入 Policy 输入。

## 1.2 AI 输出“意图”，底层确定性系统负责执行细节

LLM 不逐帧控制移动、转向、瞄准和寻路。

推荐层级：

```text
玩家 / Agent
  ↓
战略 / 战术意图
  ↓
小队或单位命令
  ↓
行为树 / 状态机 / 导航 / 战斗系统
  ↓
确定性执行
```

例如 AI 可以提出：

- 第二小队绕右侧推进；
- 守住通信站，不追击；
- 侦察北侧区域；
- 优先压制远程火力；
- 损失达到条件时撤退。

AI 不应该输出：

- 每 100 ms 向左移动 0.3 m；
- 直接设置某个 Node 的位置；
- 修改单位内部目标引用；
- 绕过技能、资源、视野和冷却规则。

## 1.3 所有控制器共享同一套权威 RTS 命令规则

Human、Rule AI、LLM、训练模型最终都必须进入同一个权威命令服务。

差异只能来自：

- 能看到什么；
- 能控制什么；
- 能多频繁观察 / 下令；
- 是否消耗操作点；
- 是否需要玩家确认；
- 决策速度和智能水平。

不能出现“玩家走正式规则，AI 调内部作弊 API”的双轨系统。

## 1.4 正式 Policy 与裁判 Evaluator 必须物理或逻辑隔离

需要明确两个数据通道：

```text
Policy Channel
- 只能得到合法受限观察
- 用于真正做决策

Evaluator Channel
- 可以读取完整真值
- 只用于记分、诊断、回放和训练标签
- 绝不回流给 Policy
```

这条边界必须能够被自动化测试验证。

## 1.5 大模型不是 RTS Core 的依赖

RTS Core 应在没有网络、没有 Python、没有任何模型 API 的情况下完整运行。

模型层只能作为 Adapter / Policy 插入。

因此：

- Core 不认识 OpenAI / DeepSeek / Ollama / llama.cpp 等具体 Provider；
- Provider 不直接调用 Godot Node；
- Prompt 格式不是游戏领域模型；
- 模型返回 JSON 也必须先转换为游戏定义的 Intent，再进入 Validator。

## 1.6 “可回放、可复现”优先于“AI 看起来聪明”

如果同一场景、同一 Seed、同一命令序列不能稳定复现，就不应该进入正式训练与模型比较阶段。

第一优先级是建立：

- 固定 Tick / 决策时刻；
- Seed；
- 稳定命令结果；
- Trace；
- Headless 场景运行；
- 固定 Benchmark。

## 1.7 第一纵向切片统一用《回声撤离》验收

AI、程序、训练、评测都不要各自造 Demo。

`单人战役_回声撤离_实现流程.md` 继续作为第一条完整游戏流程；本阶段所有关键系统都应至少能在它的“最小可运行版本”中被验证一次。

---

# 2. AI 副官权限模型

## 2.1 三种控制状态

为了兼容“AI 降低操作负担，但玩家保留最终决定权”的核心体验，建议统一成三种状态：

### A. 建议模式 Suggest

AI 可以：

- 观察允许的战场信息；
- 提出判断；
- 生成计划预览；
- 请求玩家确认。

AI 不直接改变战场状态。

适合：

- 教学阶段；
- 高风险决策；
- 玩家刚接触新系统；
- 关键剧情节点。

### B. 战术托管 Tactical Delegate

玩家把一个或多个小队的局部战术权交给 AI。

AI 可以在授权范围内自动：

- 移动；
- 攻击 / 攻击移动；
- 防守；
- 撤退；
- 选择局部目标；
- 调整阵型；
- 使用被允许的常规技能；
- 请求侦察或刷新情报。

玩家手动命令优先级始终高于托管行为。

### C. 作战托管 Operational Delegate

后续阶段允许 AI 管理更大范围的作战任务，例如：

- 多小队协同；
- 进攻路线分配；
- 防线配置；
- 侦察任务分配；
- 有限生产 / 补充建议或执行。

这一层必须在 P1/P2 再开放，不作为第一个 AI 纵向切片的前置条件。

## 2.2 默认权限原则

任何 AI 行为都需要同时通过四层判断：

```text
游戏规则允许？
    ↓
该 Controller 有权限？
    ↓
玩家当前授权范围允许？
    ↓
操作点 / 冷却 / 资源等条件满足？
    ↓
执行
```

## 2.3 必须玩家确认的操作类型

第一阶段默认采用保守策略。以下操作建议进入“确认”而不是自动执行：

- 消耗稀缺或不可逆资源；
- 改变科技 / 长期生产方向；
- 放弃核心任务目标；
- 主动牺牲英雄、剧情单位或高价值单位；
- 大范围改变多个小队当前任务；
- AI 对玩家命令存在明显歧义时；
- 任何策划标记为 `RequiresConfirmation` 的行动。

具体阈值必须数据化，不能写死在 LLM Prompt 中。

## 2.4 永久禁止的能力

无论模型能力多强，都禁止：

- 读取战争迷雾后的完整敌军真值；
- 直接访问 / 修改 Godot SceneTree、Node 或领域对象内部状态；
- 控制不属于本 Controller 且未授权的单位；
- 修改 Seed、规则、伤害、冷却、资源等权威状态；
- 通过错误码、调试接口或日志反推隐藏单位；
- 绕过命令服务直接调用单位执行函数。

---

# 3. 受限观察：策划语义

程序文档已经定义 Observation Broker 与受限观察方向；策划侧现在需要冻结“情报到底代表什么”。

## 3.1 情报至少分为四类

### Own / 自有真值

玩家自己的合法状态，例如：

- 可控制单位；
- 当前任务；
- 合法资源；
- 技能 / 冷却；
- 已知生产状态。

### Visible / 当前可见

当前视野规则允许确认的信息。

只在合法可见时提供当前事实。

### Remembered / 已知旧情报

曾经确认、现在已经失去视野的信息。

必须携带至少：

- 最后确认 Tick；
- 最后确认位置或区域；
- 数据新鲜度 / 过期状态。

不得把旧情报偷偷刷新为真实当前位置。

### Inferred / 推测情报

不是系统真值，而是根据合法信息得到的推测。

第一阶段可以只预留语义，不要求程序立刻实现复杂推断系统。

## 3.2 Unknown 必须真的 Unknown

对于未获得的情报：

- 不返回真实坐标；
- 不返回真实单位 ID；
- 不返回真实血量；
- 不通过“目标不存在 / 不是你的单位”等细粒度错误泄漏状态。

## 3.3 Observation 的最小稳定字段

这里定义语义，不要求强制使用以下 C# 命名。

每次决策输入至少能够表达：

```text
schema_version
observation_id
controller_id
decision_tick
controlled_scope
operation_budget
mission_context
own_state
visible_intel
remembered_intel
recent_visible_events
```

后续可以增加字段，但已有字段的含义不能随模型版本随意改变。

## 3.4 观察请求也属于玩法

AI 不一定每个 Tick 自动获得全量信息。

可以通过操作点形成明确取舍：

- 低成本区域摘要；
- 高成本单位详情；
- 血量 / 状态细节；
- 重新扫描旧区域；
- 高频刷新与下令之间的预算竞争。

这会让“AI 算力 / 指挥能力”真正进入玩法，而不是单纯后台性能参数。

---

# 4. 结构化意图：策划动作空间

## 4.1 第一阶段动作集合

P0 不追求覆盖所有 RTS 操作，只保证《回声撤离》需要的战术闭环。

推荐最小语义集合：

- `Move`：移动到位置 / 区域；
- `Attack`：攻击当前合法目标；
- `AttackMove`：向目标区域推进并按交战规则接敌；
- `Hold`：固守位置 / 区域；
- `Retreat`：撤向目标点 / 安全区；
- `Scout`：侦察区域；
- `Focus`：设定合法目标优先级；
- `UseAbility`：使用允许由 AI 托管的技能；
- `SetFormation`：选择已有阵型 / 队形策略；
- `CancelIntent`：中止当前 AI 意图。

如果现有 RTS Core 已经有等价命令，**直接映射现有命令，不要求为了本文档重命名代码。**

## 4.2 Intent 必须能表达的内容

建议至少具备以下语义：

```text
command_id
issued_tick
controller_id
actor_scope
intent_type
target
constraints
priority
expiry
```

其中 `constraints` 用于表达：

- 不追击；
- 最大允许损失；
- 只在某区域交战；
- 优先目标类型；
- 时间条件；
- 玩家预先配置的交战规则。

复杂自然语言必须先被拆成这些可验证字段，不能整句文本直接进入单位逻辑。

## 4.3 命令校验必须稳定

Validator 至少检查：

- Controller 是否有权限；
- actor 是否属于授权范围；
- target 是否能被合法引用；
- 当前单位是否具备该能力；
- 资源、冷却、操作点是否满足；
- 目标位置 / 区域是否合法；
- 命令是否已过期；
- 参数结构是否合法。

内部可以保留细粒度原因；对 AI 的反馈必须继续遵守战争迷雾，避免错误码侧信道。

---

# 5. 决策时序、超时与失败处理

## 5.1 AI 决策不与渲染帧绑定

AI 在明确的 Decision Tick 上读取一个快照，然后异步或同步计算决策。

模型返回后，命令只能在合法的执行时刻进入权威 Core。

不能因为某次 API 网络更快，就比另一模型多获得几个模拟帧的隐藏优势。

## 5.2 每次决策必须有截止时间

每个请求都应携带：

- request / observation id；
- decision tick；
- expiry / deadline；
- 当前允许的操作范围。

超过有效期的结果必须丢弃或按明确规则降级，不能把旧战术突然应用到已经变化的战场。

## 5.3 统一 Fallback

P0 至少实现一个确定性 fallback：

优先推荐：

1. 保持当前有效意图；
2. 若当前意图失效，进入安全的脚本策略；
3. 再无法执行时才 No-op。

网络超时、JSON 解析失败、模型拒绝回答、非法命令都不能让对局崩溃或卡死。

## 5.4 玩家手动接管

玩家手动命令进入同一命令服务，但拥有高于 AI 托管计划的控制优先级。

当玩家接管某个 scope：

- 立即暂停 / 取消冲突中的 AI Intent；
- 记录接管事件；
- 在设定冷却时间内，AI 不重新覆盖；
- 后续可选择恢复原计划或基于新位置重新规划。

---

# 6. Agent / Provider 接入边界

## 6.1 程序应提供统一 Policy 抽象

名称可以由程序侧决定，但语义上需要统一入口：

```text
Policy.Decide(observation, context)
    → ProposedIntent(s)
```

至少支持四类实现：

1. `ScriptedPolicy`：确定性脚本基线；
2. `MockPolicy`：自动化测试；
3. `RemoteLLMPolicy`：远程大模型；
4. `LocalModelPolicy`：本地推理模型。

未来训练模型继续实现同一语义，不改变 RTS Core。

## 6.2 LLM Adapter 负责什么

LLM Adapter 只负责：

- 把受限 Observation 转成模型输入；
- 提供允许的工具 / 动作 Schema；
- 调用 Provider；
- 解析模型输出；
- 转换成 ProposedIntent；
- 记录 token、延迟、Provider、模型版本等运行信息。

LLM Adapter 不负责：

- 判断游戏规则最终是否合法；
- 直接改变单位状态；
- 读取隐藏世界；
- 自己实现战争迷雾；
- 维护第二套单位数据。

## 6.3 Provider 与游戏解耦

建议运行配置至少能描述：

```text
provider_id
model_id
endpoint / local backend
timeout
sampling settings
prompt_version
tool_schema_version
```

API Key 只属于运行环境 / Secret 管理，不进入仓库、不进入 Replay、不进入训练数据。

## 6.4 Prompt 必须版本化

Prompt 是 Policy 的一部分，不是临时文本。

任何会影响行为的系统提示词、工具说明、动作约束，都应有 `prompt_version`，并进入 Trace。

否则同一个模型 ID 在两次评测中的结果不可比较。

---

# 7. Trace、Replay 与训练数据合同

## 7.1 为什么现在就要做 Trace

Trace 不是模型接入完成后的日志功能，而是 AI 开发的基础设施。

没有 Trace，就无法回答：

- 模型当时看到了什么？
- 为什么下了这个命令？
- 命令被拒绝还是执行失败？
- 是策略变差，还是地图 / 数值变了？
- 延迟和 token 成本是多少？
- 某个训练样本对应哪版游戏？

## 7.2 Episode 元数据

每局至少记录：

```text
episode_id
repo_commit_sha
engine_version
scenario_id
scenario_version
map_id
seed
difficulty
observation_schema_version
intent_schema_version
policy_type
policy_version
provider_id / model_id（如有）
prompt_version（如有）
```

Godot 版本应能明确区分当前统一规范使用的 Mono 版本。

## 7.3 每个 Decision Step 至少记录

```text
step_id
decision_tick
observation_id
observation_hash
policy_input_version
proposed_intent
validation_result
accepted_intent
applied_tick
visible_feedback
internal_result_ref
latency_ms
token_usage（如有）
fallback_reason（如有）
```

注意：训练导出时需要再次执行权限 / 隐私过滤，不能因为内部 Trace 有裁判真值，就把真值一起喂给 Policy。

## 7.4 数据集必须可追溯

每条训练轨迹必须能追溯回：

```text
游戏版本 + 场景版本 + Seed + Policy/玩家来源 + Schema 版本
```

不能保存一堆“observation → command”的裸 JSON 后再也不知道它来自哪版游戏。

---

# 8. 训练路线

## 8.1 阶段 A：先建立脚本基线，不训练

目标不是让脚本 AI 很强，而是建立可比较的下限。

需要至少：

- 固定场景；
- 固定 Seed 集；
- ScriptedPolicy；
- 全量 Trace；
- 自动算分。

这一步完成后，才知道后面的 LLM / 训练模型到底有没有变好。

## 8.2 阶段 B：模仿学习 / 行为克隆

优先数据来源：

1. 策划或程序编写的高质量 ScriptedPolicy；
2. 人类玩家操作轨迹；
3. 更强 Teacher Policy 产生并经规则过滤的轨迹。

训练输入只使用正式 Policy 能看到的信息。

训练目标优先学习：

- 合法动作选择；
- 目标选择；
- 撤退时机；
- 编队 / 路线等战术意图；
- 低级别多步任务分解。

## 8.3 阶段 C：课程学习 Curriculum

不要一开始直接训练完整 RTS。

推荐顺序：

```text
单一移动 / 到达
→ 单目标交战
→ 侦察 + 接敌
→ 撤退 / 固守
→ 双小队协同
→ 条件命令
→ 资源 / 生产
→ 完整《回声撤离》
→ 多地图 / 多对手
```

每升一级都必须保留前一级 Benchmark，防止新能力导致旧能力退化。

## 8.4 阶段 D：强化学习 / Self-play

只有在以下条件都成立后再做：

- Headless 模拟稳定；
- Seed 与回放稳定；
- Observation / Intent Schema 已版本化；
- Reward 可以拆解；
- 固定 Benchmark 已建立；
- Scripted / LLM / imitation baseline 已有可比较结果。

否则 RL 只会放大模拟器漏洞或奖励函数漏洞。

## 8.5 Reward 不只看输赢

至少拆为多个可观察分量：

- 任务完成；
- 任务阶段推进；
- 时间效率；
- 单位价值交换；
- 自身损失；
- 资源效率；
- 关键单位存活；
- 非法命令惩罚；
- 超时 / fallback；
- 可选：操作点效率。

权重在有 baseline 数据前不要提前锁死。

---

# 9. 评测体系

评测分三层，不能只看 Win Rate。

## 9.1 L0｜协议与规则正确性

必须自动化验证：

- Observation Schema 可解析；
- Intent Schema 可解析；
- 非法命令不会破坏状态；
- 无权限目标不能控制；
- 战争迷雾信息不会进入 Policy；
- 细粒度内部错误不会通过 AI 反馈泄漏；
- 超时 / 解析失败会进入确定性 fallback；
- 同一版本、同一 Seed、同一命令流满足项目定义的确定性要求。

**L0 不通过，禁止进入模型强弱比较。**

## 9.2 L1｜游戏能力

至少统计：

- 任务完成率；
- 每个任务阶段到达率；
- 完成时间；
- 单位损失价值；
- 敌我交换效率；
- 关键单位存活率；
- 资源 / 操作点效率；
- 侦察覆盖与情报新鲜度；
- 撤退成功率；
- 条件命令执行正确率。

## 9.3 L2｜AI 工程质量

至少统计：

- Intent 合法率；
- 命令拒绝率及原因分布；
- 超时率；
- fallback 率；
- 推理延迟 p50 / p95；
- token 使用量；
- 单局模型成本；
- 输出解析失败率；
- 同一 Benchmark 的行为方差。

本地模型没有 token 成本时，改记推理时间、显存 / 内存等运行指标。

## 9.4 Baseline 层级

每个正式 Benchmark 至少保留：

1. No-op / 极弱基线（只在有意义的场景使用）；
2. Scripted baseline；
3. 当前正式 AI baseline；
4. Candidate policy。

Candidate 必须和 baseline 跑同一批场景 / Seed，不能只挑对自己有利的对局。

## 9.5 阈值如何确定

当前阶段不凭感觉写死“胜率必须 80%”之类数字。

流程是：

1. 先跑 Scripted baseline；
2. 获得可重复的数据分布；
3. 再锁定回归阈值；
4. 阈值进入 CI / Benchmark 配置；
5. 修改阈值必须有版本记录。

---

# 10. 《回声撤离》作为第一条端到端 AI 验收链

不改变原关卡文档的剧情和关卡流程，这里只定义它如何承担系统验收。

## 10.1 最小 AI Slice

第一版不要求完整战役内容，只抽取能够闭环的最小流程：

```text
进入任务
→ 获取合法初始情报
→ 选择 / 接受一个战术目标
→ AI 控制授权小队移动
→ 发生首次接敌
→ AI 根据合法情报战斗 / 撤退 / 固守
→ 玩家可手动接管
→ 达成撤离或失败条件
→ 输出完整 Trace 与评测结果
```

## 10.2 每个关卡阶段都必须回答 5 个问题

后续细化《回声撤离》时，每一个阶段都补齐：

1. AI 此时合法知道什么？
2. AI 此时可以下哪些 Intent？
3. 哪些动作必须玩家确认？
4. 程序依赖哪些 Core / Mission / Fog / Command 系统？
5. 自动化验收条件是什么？

## 10.3 第一阶段重点验证，而不是堆内容

P0 Slice 优先证明：

- 受限观察是真实生效的；
- AI 不需要直接读 Node；
- Structured Intent 可以完成任务；
- 玩家接管不会与 AI 抢控制；
- 超时失败不破坏对局；
- 同一局可以被 Trace / Replay / Evaluator 解释。

只要这条链正确，后续才能安全增加更多兵种、技能、地图和模型。

---

# 11. 程序下一步开发顺序

以下顺序视为当前推荐依赖顺序。前一层没有稳定前，不要为了“先看到 AI 聊天效果”跳层开发。

## P0-1｜冻结 Observation / Intent / Result 的版本化语义

程序交付：

- Observation DTO / Snapshot 边界；
- Intent / Command DTO 边界；
- 内部 Result 与 AI 可见 Feedback 分离；
- Schema version；
- 序列化测试。

策划交付：

- 权限表；
- 情报语义；
- 第一版动作空间；
- 风险 / 确认规则。

完成标准：

- ScriptedPolicy 和未来 LLM 可以使用同一合同；
- DTO 不引用 Node；
- AI 可见结果不泄漏隐藏真值。

## P0-2｜Headless Scenario Runner + Seed

程序交付：

- 无 UI 运行最小场景；
- 可指定 Scenario / Seed；
- 可注入 Policy；
- 可输出结构化结果。

完成标准：

- CI 或命令行可以跑最小测试；
- 不依赖人工点击才能完成一局。

## P0-3｜ScriptedPolicy 基线

程序 / 策划共同交付：

- 一个只使用合法 Observation 的脚本 AI；
- 能通过最小“回声撤离”流程；
- 不走任何专用作弊入口。

完成标准：

- 它成为所有后续 AI 的第一基线。

## P0-4｜Trace / Replay / Evaluation 基础

程序交付：

- Episode Trace；
- Decision Step Trace；
- 游戏版本 / Seed / Schema / Policy 元数据；
- 基础指标汇总；
- 失败原因可定位。

完成标准：

- 任意一场 Benchmark 可以回答“看到了什么、下了什么、为什么成功或失败”。

## P0-5｜《回声撤离》最小 AI Slice

程序交付：

- 场景状态机与 AI 接口打通；
- 玩家接管；
- 受限观察；
- 基础命令；
- 胜败；
- 自动评测。

完成标准：

- 不接 LLM，也能用 ScriptedPolicy 完整跑通。

## P1-1｜统一 Agent Adapter

程序交付：

- Policy 接口；
- Mock / Scripted / Remote LLM / Local Model Adapter 插槽；
- timeout；
- cancellation；
- deterministic fallback。

完成标准：

- 切换模型不修改 RTS Core。

## P1-2｜LLM 接入

第一阶段只做一个远程 Provider + 一个 Mock 即可，不同时维护大量供应商。

重点验证：

- Observation → Prompt；
- Tool / Intent Schema；
- 解析；
- timeout；
- token / latency trace；
- 非法命令处理。

## P1-3｜训练数据导出

交付：

- 从 Trace 生成 Dataset；
- 训练输入严格使用 Policy Channel；
- episode / seed / schema / source 可追溯；
- 支持 train / validation / test 按场景与 Seed 隔离。

## P1-4｜Benchmark Runner

交付：

- 固定 Benchmark manifest；
- 批量运行多个 Seed；
- baseline / candidate 对比；
- JSON / CSV 结果；
- 回归判定。

## P2｜训练与 Self-play

只有 P0/P1 的可复现链路稳定后再进入。

---

# 12. 建议的第一个程序 Sprint

如果下一轮只允许做一个 Sprint，建议不要先做聊天 UI，而是完成：

```text
1. ObservationEnvelope / Intent / Feedback 的最小版本化 DTO
2. ScriptedPolicy
3. DecisionScheduler
4. Command Validator 对接
5. Headless 最小场景
6. EpisodeTrace
7. 固定 Seed 回归测试
```

Sprint 结束时应该可以执行类似概念流程：

```text
load scenario + seed
→ create ScriptedPolicy
→ produce restricted observation
→ policy returns intent
→ validate and apply
→ run until terminal state
→ save trace
→ calculate metrics
```

**这比“先让大模型成功说一句话”更重要，因为它会成为之后所有 AI 的地基。**

---

# 13. P0 验收门槛

进入正式 LLM 对局前，至少满足：

- [ ] AI 不能通过任何正式接口获得完整隐藏世界状态；
- [ ] Observation / Intent / Feedback 有明确版本；
- [ ] ScriptedPolicy 不依赖 Node；
- [ ] 非法命令不会崩溃或破坏 Core；
- [ ] AI 超时 / 无响应 / 解析失败有确定性 fallback；
- [ ] 可以 Headless 跑一个最小场景；
- [ ] 可以指定 Seed；
- [ ] 每局产生可追溯 Episode Trace；
- [ ] 可以统计至少 L0 + 基础 L1 指标；
- [ ] 玩家手动接管的优先级高于 AI；
- [ ] 《回声撤离》最小 Slice 能由 ScriptedPolicy 跑通；
- [ ] 同一个测试案例可用于未来 LLM / 本地模型 / 训练模型横向比较。

---

# 14. 本阶段明确不做

为了控制范围，以下内容不是当前 P0 前置条件：

- 完整多阵营 Self-play；
- 大规模 RL 基础设施；
- 多 Provider 同时深度适配；
- 让 LLM 逐帧微操；
- 以屏幕像素视觉作为唯一正式控制方式；
- AI 自动生成完整战役；
- 复杂长期记忆；
- 完整经济 / 生产战略 Agent；
- 为了 AI 接入重新绕开或重写现有 RTS Core。

Pixel Controller / 视觉识别可以保留为后续研究 Adapter，但不应成为领域层依赖，也不阻塞首个结构化 AI 纵向切片。

---

# 15. 后续策划文档的细化顺序

从本文档开始，策划侧按依赖关系继续拆，不再平铺式补文档：

1. **AI 副官权限表**：精确到每类命令的自动 / 确认 / 禁止；
2. **战争迷雾与情报规则**：Visible / Remembered / Inferred 的生命周期；
3. **单位与技能标准**：稳定第一版动作空间和能力标签；
4. **《回声撤离》阶段表**：每阶段 Observation / Intent / Confirmation / Pass Criteria；
5. **操作点规则**：观察、下令、刷新情报的成本和恢复；
6. **Benchmark 场景集**：从单能力测试到完整任务；
7. **训练数据规范**：样本选择、切分、版本与质量标签。

后续任何新 AI 玩法，都优先判断它落在哪一层：

```text
情报规则？
权限规则？
Intent 动作空间？
底层确定性执行？
Policy 智能？
训练数据？
Evaluator？
```

只有先分清层级，项目才不会再次把“大模型能力”和“游戏系统能力”混在一起。
