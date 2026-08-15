# 程序重构：Legacy GDScript 允许清单与权威写入审计评审稿

> 对应进度：`ARCH-015`
>
> 状态：规则评审中，尚未建立自动门禁
>
> 日期：2026-08-15

## 1. 目标

本项不以删除全部 GDScript 为目标，而是确保剩余脚本只能承担已经登记的 Godot 表现、输入翻译、引擎执行端或冻结功能。Human、传统 AI、HUD、战役脚本和未来外部 Agent 不得直接修改 Action、HP、玩家余额、生产队列或生成生命周期。

最终交付物建议包含：

- 一份机器可读允许清单；
- 一个可重复执行且发现未知写入时返回非零退出码的扫描脚本；
- 一份说明每类 Legacy 写入调用方向、保留原因和替换目标的文档；
- 最终回归时保存扫描结果。

## 2. 当前扫描结论

已扫描 `source/**/*.gd` 中以下高风险形式：

- `action =`、`.action =` 与动态 `set("action", ...)`；
- `hp =`、`.hp =`、`set_hp_without_damage(...)` 与动态 HP 写入；
- `resource_a/resource_b` 的赋值、加减和动态写入；
- `setup_and_spawn_unit.emit(...)`；
- 施工初始化、进度应用和取消入口；
- Human、传统 AI、HUD、战役目录中的同类写入。

当前没有发现以下禁止旁路：

- `players/human` 直接赋值单位 Action、HP 或玩家余额；
- `simple-clairvoyant-ai` 直接赋值单位 Action、HP、余额或直接生成单位；
- `AICommandHUD`、传统 HUD 或单位菜单直接清空 Action；
- `campaign` 绕过公共命令或经济服务修改权威状态；
- 通过 `set("action")`、`set("hp")` 等动态属性调用隐藏上述写入。

`GenericMenu.gd` 已在缺少 Gateway 时报告错误，不再回退为直接清空 Action。生产菜单仍调用 `unit.production_queue.produce(...)`，但该方法只是提交到 C# `ProductionRuntime.Enqueue` 的输入 Adapter，不自行扣款或推进队列。

## 3. 建议允许清单

### 3.1 单位 Action 执行端

允许文件：

- `source/match/units/Unit.gd`；
- `source/match/units/Tank.gd`；
- `source/match/units/Helicopter.gd`；
- `source/match/units/AntiGroundTurret.gd`；
- `source/match/units/AntiAirTurret.gd`。

允许原因：`GodotAdapter` 端口调用 `Unit.gd` 的桥接方法创建 Legacy Action；具体单位在 Action 完成后安装 `WaitingForTargets`，属于当前自动索敌执行状态机。

限制：

- Human、AI、HUD、战役和外部接口只能调用 C# Gateway/Runtime；
- 新单位不得因为类型未登记而在上层增加直接 Action 回退；
- Action 脚本只能修改自身或通过 `Unit.gd` 已登记的执行入口完成状态转换。

后续替换目标：导航、动画和武器表现稳定后，可逐类把 Legacy Action 改为 C# GodotAdapter 状态节点；不阻塞本次重构。

### 3.2 HP 与施工表现执行端

允许文件：

- `source/match/units/Unit.gd`；
- `source/match/units/Structure.gd`；
- `source/match/debug/UnitsManager.gd`。

允许原因：`Unit.gd` 是当前 Godot 伤害落点和死亡表现；`Structure.gd` 镜像 C# 权威施工工作量到 HP；`UnitsManager.gd` 只在显式 God Mode 下提供测试删除。

限制：Human、AI、普通 HUD 和战役不得直接写 HP；非伤害 HP 必须走已登记的 `set_hp_without_damage`，真实伤害必须保持投射物视觉与结算一致。

### 3.3 采集现场库存与 Worker 载荷

允许文件：

- `source/match/units/Worker.gd`；
- `source/match/units/non-player/ResourceA.gd`；
- `source/match/units/non-player/ResourceB.gd`；
- `source/match/units/actions/CollectingResourcesWhileInRange.gd`；
- `source/match/units/actions/CollectingResourcesSequentially.gd`；
- `source/match/players/Player.gd`。

允许原因：玩家账户已经由 C# 权威管理，`Player.gd` 只接收余额快照；资源节点库存与 Worker 在途载荷仍属于已验收采集 Action 的 Legacy 现场执行状态，只有交付成功后才通过资源交易进入玩家账户。

限制：新经济奖励、建筑收入、生产消费和退款不得修改这些字段或把玩家账户重新绑定到采集；上层只调用 C# 账户与命令接口。

后续替换目标：在资源刷新、劫掠、载荷转移等机制确定后，将资源节点库存和 Worker Cargo 独立迁移为 C# 服务；本次只登记现状，不新增规则。

### 3.4 生产部署与实体装配

允许文件：

- `source/match/units/traits/ProductionQueue.gd`；
- `source/match/Match.gd`。

允许原因：C# `ProductionService` 决定队列、成本、进度和完成；Legacy `try_deploy_authoritative` 只寻找 Godot 可部署位置并请求 Match 组合根实例化实体。Match 是唯一将实体加入玩家节点和 SceneTree group 的装配边界。

限制：HUD 和 AI 只能提交生产请求；不得直接发出 `setup_and_spawn_unit`。未来传送、空投等特殊部署也必须实现新的受权部署端口，而不是让调用者直接生成。

### 3.5 施工节点表现

允许文件：

- `source/match/Match.gd`；
- `source/match/units/Structure.gd`。

允许原因：Match 在 C# 放置验证通过后创建蓝图；Structure 接收 C# 施工快照、完成和取消调用，负责材质、HP 镜像和 Legacy Signal。

限制：施工成本、进度、Builder 分配、退款和摧毁结果仍由 C# 服务决定；GDScript 不得自行推进工作量。

### 3.6 表现、输入、冻结模块与调试

允许保留但不允许权威写入：

- HUD、HealthBar、Minimap、语音与鼠标输入翻译；
- 已迁移为公共查询和命令调用者的规则 AI 策略脚本；
- 冻结 AI 副官与战役任务表现；
- `match/debug` 下由显式 Feature Flag/God Mode 限制的工具。

冻结不等于允许绕过。扫描器发现这些目录新增 Action、HP、余额、生成或队列内部写入时必须失败。

## 4. 机器门禁设计

建议新增：

```text
config/legacy_gdscript_authority_allowlist.json
tools/audit_legacy_gdscript_authority.ps1
```

JSON 每一类至少包含：

- `id`：稳定类别 ID；
- `pattern`：需要扫描的高风险写入模式；
- `allowed_files`：允许出现该模式的精确仓库相对路径；
- `reason`：保留原因；
- `replacement_scope`：后续替换方向或明确“仅表现”。

扫描脚本应：

1. 递归读取 `source/**/*.gd`，不扫描 `.godot`、导入产物和测试场景；
2. 按类别查找高风险写入；
3. 输出类别、文件和行号；
4. 发现未登记文件时返回非零退出码；
5. 允许文件不存在、路径重复、空原因或未知 schema 时也返回非零退出码；
6. 成功空结果必须明确输出，不得静默；
7. 不自动修改代码或清单。

首版只做文本静态门禁，不声称能够理解全部 GDScript 语义。最终验收仍需结合代码审查；动态属性、反射调用和新增权威字段应同步扩展扫描类别。

## 5. 建议评审结论

建议确认：

1. 本次重构允许保留上述六类 GDScript 边界，不要求文件数量归零；
2. Human、规则 AI、HUD、战役和外部 Agent 维持“只能调用公共 C# 边界”的硬规则；
3. 资源节点库存与 Worker Cargo 暂列 Legacy 执行状态，玩家账户仍保持独立 C# 权威；
4. `ProductionQueue.gd` 的部署和 `Match.gd` 的实体装配属于 C# 决策后的 Godot 端口，不属于生产规则旁路；
5. Debug HP 写入只允许存在于 `match/debug` 且受 God Mode 限制；
6. 新增机器可读 JSON 和 PowerShell 扫描脚本，未知写入使最终验收失败；
7. 允许清单只允许精确文件路径，不接受整个目录通配放行；
8. 新增一种权威字段或动态写法时必须先更新审计规则并经过评审；
9. 本轮只建立门禁并清除未登记旁路，不借机重写导航、采集表现或冻结战役；
10. ARCH-015 完成条件为：扫描脚本通过、人工复核无未知旁路、完整回归无行为变化。
