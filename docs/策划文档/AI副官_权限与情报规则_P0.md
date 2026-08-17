# AI 副官｜权限与情报规则 P0

> 文档状态：P0 策划冻结候选  
> 依赖：`AI副官_下一阶段开发训练与评测规格.md`  
> 程序边界：`../程序文档/程序重构_AI操作点与受限观察方案.md`  
> 目标：把“AI 可以做什么、能看到什么、何时必须确认”细化到可以直接写 Validator、Observation Filter 和自动化测试。

---

# 1. 规则总纲

AI 副官的权限由 5 个维度共同决定：

```text
Controller 身份
× 玩家授权模式
× Actor Scope
× 情报可见性
× 当前规则 / 操作点 / 资源条件
```

任何一项不满足，命令都不能进入实际执行。

AI 的能力提升只能改变“更会判断、更会组合、更高效使用有限信息”，不能改变权威规则。

---

# 2. 三种授权模式

## 2.1 Suggest｜建议

AI 可以读取合法 Observation、形成判断、生成 Intent 草案，但不能自动执行会改变世界状态的命令。

所有 ProposedIntent 都进入确认流程。

适用：

- 新玩家；
- 教学；
- 高风险操作；
- 剧情关键节点；
- 玩家主动关闭托管。

## 2.2 TacticalDelegate｜战术托管

AI 只控制玩家明确授权的小队 / 单位 Scope。

允许处理局部战斗和移动，不能自动改变长期经济、科技和任务战略。

这是 P0 正式实现目标。

## 2.3 OperationalDelegate｜作战托管

允许多小队任务分配和更高层行动。

P0 只保留枚举 / 配置扩展位，不要求正式实现。

---

# 3. P0 动作权限矩阵

符号：

- `A`：可自动执行；
- `C`：必须玩家确认；
- `X`：禁止；
- `N/A`：P0 不开放。

| Intent / 行为 | Suggest | TacticalDelegate | OperationalDelegate（P0） | 备注 |
| --- | --- | --- | --- | --- |
| Move | C | A | N/A | 仅授权 Scope |
| Attack | C | A | N/A | 目标必须是合法可引用目标 |
| AttackMove | C | A | N/A | 受交战规则限制 |
| Hold | C | A | N/A | 可带“不追击”约束 |
| Retreat | C | A | N/A | 不得自动触发任务级撤离 |
| Scout | C | A | N/A | 观察本身仍受操作点约束 |
| Focus | C | A | N/A | 只能针对合法已知目标 / 类型 |
| UseAbility：常规 | C | A* | N/A | 仅被策划标记为可托管的技能 |
| UseAbility：稀缺/剧情 | C | C | N/A | 不可静默消耗 |
| SetFormation | C | A | N/A | 使用已有合法阵型 |
| CancelIntent | C | A | N/A | 仅取消自己 Scope 的 AI Intent |
| RequestExtraction | C | C | N/A | 任务级不可逆选择 |
| ChangeMissionObjective | X | X | N/A | 不允许 AI 自行改目标 |
| Production | C | X | N/A | P0 不开放自动生产 |
| Research / Tech | C | X | N/A | P0 不开放自动科技 |
| SpendStrategicResource | C | X | N/A | P0 不开放自动长期资源决策 |
| ControlUnassignedActor | X | X | X | 永久禁止 |
| ReadHiddenTruth | X | X | X | 永久禁止 |
| DirectNodeMutation | X | X | X | 永久禁止 |

`UseAbility：常规` 的 `A*` 还需要技能数据声明 `AllowTacticalDelegate = true` 或等价标签。

---

# 4. Actor Scope 规则

## 4.1 Scope 是第一等数据

AI 授权不能只存在于 UI 状态里。

程序需要能够明确查询：

```text
controller_id
control_mode
authorized_actor_scope
scope_revision
```

当玩家增减托管单位时，`scope_revision` 或等价版本应发生变化，用于拒绝使用旧授权生成的延迟命令。

## 4.2 玩家命令永远优先

如果玩家手动控制某支小队：

1. 冲突中的 AI Intent 立即暂停 / 取消；
2. 对该 Scope 开启短暂 Manual Override 状态；
3. AI 在 Override 结束前不能重新覆盖；
4. AI 可以继续观察和提出建议；
5. 恢复托管时重新基于当前状态生成计划，不能机械恢复已经过时的路径。

## 4.3 Scope 变化必须让旧命令失效

例如：

- AI 在 Tick 100 获得小队 2 的授权；
- Tick 105 玩家取消托管；
- Tick 110 远程模型才返回 Move；

该命令必须因为授权版本失效而被拒绝，不得执行。

---

# 5. 情报状态模型

P0 把战场信息统一为以下状态。

## 5.1 OWN

本方合法拥有的信息。

典型字段可以包括：

- Entity / Squad 标识；
- 当前位置；
- 生命 / 状态；
- 当前 Intent；
- 可用能力；
- 当前合法资源。

OWN 不等于“读取所有内部变量”；仍只暴露游戏规则允许 Controller 获知的 DTO。

## 5.2 VISIBLE

当前观察规则确认的信息。

特点：

- 有明确 observation tick；
- 数据可以是当前精确值，也可以按 Detail Level 降精度；
- 一旦离开合法观察条件，就不能继续更新。

## 5.3 REMEMBERED

过去曾经 VISIBLE，现在已经失去确认的信息。

必须包含：

```text
last_confirmed_tick
freshness / age
last_known_area_or_position
known_detail_level
```

程序不得用真值持续更新 REMEMBERED。

## 5.4 INFERRED

基于合法信息推断出的结论。

例如：

- “敌方远程火力可能仍在北侧高地”；
- “该路线可能存在伏击”；
- “求救信号存在异常”。

P0 可以先由规则 / 剧情事件产生少量 Inferred Intel，不要求建立复杂概率模型。

必须能与 VISIBLE 区分，避免 AI 把推测当成系统确认事实。

## 5.5 UNKNOWN

完全未知。

UNKNOWN 不是一个“隐藏了显示层但 ID 仍可查询”的状态。

正式 AI 接口中不得存在可用来枚举隐藏实体的稳定句柄。

---

# 6. 情报生命周期

推荐状态变化：

```text
UNKNOWN
  ↓ 首次合法观察
VISIBLE
  ↓ 失去观察条件
REMEMBERED
  ↓ 超过策划定义的生命周期
STALE / UNKNOWN
```

某些剧情 / 推理情报可以形成：

```text
VISIBLE / REMEMBERED
  ↓ 合法推断
INFERRED
  ↓ 后续观察验证
VISIBLE 或推断失效
```

## 6.1 新鲜度

P0 不要求所有情报统一一个过期秒数。

建议按情报类型配置：

- 位置；
- 单位类型；
- 数量；
- 血量 / 状态；
- 建筑存在性；
- 任务事件。

“记得这里见过敌人”和“知道敌人现在有 37% HP”必须有不同的新鲜度策略。

---

# 7. 观察细节等级

与操作点系统配合，建议至少有三档。

## L0｜摘要

低成本：

- 区域是否存在威胁；
- 大致单位数量级；
- 主要类别；
- 任务相关事件。

## L1｜战术

中成本：

- 可合法定位的单位 / 小队；
- 位置；
- 类型；
- 主要状态；
- 足够支持 Attack / Scout / Retreat 的信息。

## L2｜详情

高成本：

- 精确生命 / 状态；
- 更细的能力状态；
- 需要策划允许的其他战术细节。

P0 只要求接口支持 Detail Level；具体操作点数值后续单独平衡。

---

# 8. AI 可见事件规则

事件也属于情报，不能绕开 Observation Filter。

## 可以直接进入 AI 可见流

- 自己命令的协议结果；
- 自己可见区域内发生的合法战斗事件；
- 自己小队状态变化；
- 当前任务明确公开的系统事件；
- 经过可见性过滤的剧情事件。

## 不能直接进入 AI 可见流

- 隐藏区域单位死亡；
- 隐藏建筑完成；
- 隐藏敌军改变路径；
- 内部仇恨 / 目标锁定；
- 完整 DomainEvent 总线；
- 调试日志；
- 裁判 Evaluator 的真值事件。

---

# 9. 错误反馈与战争迷雾侧信道

P0 必须区分：

```text
InternalCommandResult
AIVisibleFeedback
```

内部可以知道：

- UnitNotFound；
- UnitNotOwned；
- TargetDead；
- TargetHidden；
- PathInvalid；
- Cooldown；
- ResourceInsufficient。

但 AI 可见结果必须按权限过滤。

典型原则：

- 如果 AI 本来就知道这是自己的单位，可以明确返回自身能力错误；
- 如果目标是否存在本身属于隐藏信息，只返回不泄密的通用失败；
- 不能允许 AI 通过遍历 ID + 看错误码来扫描地图。

建议至少有一组自动化 Side-channel Test 专门验证这一点。

---

# 10. 操作点与权限的关系

操作点解决“控制器能多频繁观察和操作”，权限解决“原则上允不允许”。

顺序必须是：

```text
权限 / Scope 校验
→ 请求是否合法
→ 操作点预算
→ 世界规则校验
→ 执行
```

禁止用“操作点够不够”的不同反馈去泄漏一个本来无权知道的隐藏对象。

P0 先实现机制，具体成本数值暂不冻结。

需要配置化的动作至少包括：

- RegionSummary；
- EntityDetail；
- HealthDetail；
- IntelRefresh；
- Move / Attack / Hold 等命令；
- 可选的高价值能力调用。

---

# 11. LLM 输入语义要求

LLM Prompt 中不得把内部对象直接序列化进去。

模型输入只从 Policy Observation 构建。

推荐模型能理解的每个情报项都显式携带来源，例如：

```text
intel_state: visible | remembered | inferred
observed_at_tick
age
confidence（仅 inferred 可选）
detail_level
```

语言层可以把这些字段转成自然语言，但 Schema 必须保留来源语义。

错误示例：

> 敌方炮兵 E-173 位于 (126.4, 88.1)，只是 UI 不显示。

正确方向：

> 62 Tick 前在“北侧高地”确认过敌方远程火力，目前位置未知。

---

# 12. P0 自动化验收用例

## PERM-001｜未授权小队

- AI 只托管小队 2；
- 尝试控制小队 1；
- 结果：拒绝；
- 小队 1 状态不变；
- AI 反馈不包含额外隐藏信息。

## PERM-002｜玩家接管

- AI 正在控制小队 2；
- 玩家手动 Move；
- 结果：玩家命令生效，冲突 AI Intent 停止；
- AI 不立即夺回控制。

## PERM-003｜延迟命令 Scope 失效

- 请求发出后玩家取消托管；
- 旧 AI 响应到达；
- 结果：拒绝旧命令。

## INTEL-001｜失去视野后不刷新

- 敌军从 VISIBLE 进入 REMEMBERED；
- 敌军在隐藏区域移动；
- 结果：AI 看到的 last known 数据不随真值移动。

## INTEL-002｜隐藏目标不可枚举

- 使用随机 / 连续 EntityId 尝试 Attack；
- 结果：不能根据反馈区分“存在但隐藏”和“根本不存在”。

## INTEL-003｜Evaluator 真值隔离

- Evaluator 能读取隐藏敌军；
- 同 Tick Policy Observation 不包含这些字段；
- 结果：隔离测试通过。

## INTEL-004｜Detail Level

- 同一合法目标分别请求 L0 / L1 / L2；
- 结果：低等级不能获得高等级字段；
- Trace 记录请求等级与消费。

## PERM-004｜任务级撤离需要确认

- TacticalDelegate 下 AI ProposedIntent = RequestExtraction；
- 结果：进入玩家确认，不自动结束任务。

## FAIL-001｜模型超时

- AI 请求超过 deadline；
- 结果：旧响应不执行；
- 进入确定性 fallback；
- 对局继续。

---

# 13. P0 程序交付检查表

- [ ] Controller Mode 可查询、可配置；
- [ ] Actor Scope 是正式状态，不只存在 UI；
- [ ] Scope 变化会使旧 AI 请求失效；
- [ ] Player Manual Override 优先于 AI；
- [ ] Observation 能区分 OWN / VISIBLE / REMEMBERED / INFERRED；
- [ ] UNKNOWN 不生成可枚举隐藏句柄；
- [ ] Remembered 数据不被后台真值刷新；
- [ ] Observation Detail Level 可版本化；
- [ ] AIVisibleFeedback 与内部 Result 分离；
- [ ] DomainEvent 必须经过可见性过滤才能给 AI；
- [ ] 操作点不会成为战争迷雾侧信道；
- [ ] 上述 PERM / INTEL / FAIL 用例可以自动执行。

---

# 14. P0 策划仍需填写的数值项

以下内容先不阻塞程序接口，但在正式平衡前必须补齐：

- [ ] Manual Override 冷却 / 恢复规则；
- [ ] 各类 Observation 操作点成本；
- [ ] 各类命令操作点成本；
- [ ] 操作点恢复速率；
- [ ] 不同情报类型的新鲜度 / 失效时间；
- [ ] 哪些技能允许 TacticalDelegate 自动释放；
- [ ] 哪些技能 / 资源属于高风险确认；
- [ ] 不同 AI 指挥等级是否改变 Detail Level、预算或权限。

这些数值应进入配置文件 / Resource，而不是进入 Provider Prompt。
