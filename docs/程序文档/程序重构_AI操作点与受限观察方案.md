# 程序重构：AI 操作点与受限观察方案

> 文档状态：初步方案，供后续独立接口评审
>
> 当前重构范围：只预留边界，不实现大模型或 Python 接入

## 1. 目标

Human、传统决策树 AI 和大模型 AI 最终调用同一套权威 RTS 命令接口，但控制器获得的信息、操作频率和反馈不必相同。大模型必须通过受限观察获取世界信息，不能读取场景树、完整快照、原始命令错误或全部领域事件。

## 2. 核心分层

```text
Controller (Human / Rule AI / LLM)
  → controller policy and operation-point budget
  → commands                         observation requests
  → authoritative command service    → observation broker
  → game state and domain events      → fog/detail/freshness filter
                                      → ObservationEnvelope
```

- 命令服务决定游戏规则中的“能否执行”，始终产生内部 `CommandResult`；
- 领域事件记录“之后发生了什么”，例如移动到达或建造完成；
- 操作点预算决定控制器能否在当前时间窗发起某类命令或观察；
- 观察代理决定控制器能看到什么，不允许通过反馈旁路获取隐藏信息。

## 3. 操作点建议

操作点属于控制器能力限制，不属于矿物、电力等游戏经济资源。建议预留：

```csharp
public interface IControllerBudgetService
{
    BudgetDecision TryConsume(ControllerId controllerId, OperationCost cost, long tick);
}
```

可计费行为包括：区域扫描、实体详情、血量详情、刷新旧情报、下达单位命令，以及可选的镜头/鼠标模拟。费用、恢复速率和时间窗均通过版本化配置定义，不写死在命令对象中。

## 4. 观察请求与结果

建议观察类型至少包括：

- 区域摘要：较低成本，只返回范围内允许获知的概要；
- 单位详情：较高成本，返回某个可见单位的详细状态；
- 血量/状态详情：单独的细节层级与成本；
- 情报刷新：重新观察相同区域，结果可能没有变化但仍消耗点数。

所有结果必须经过战争迷雾和权限过滤，并携带：观察时刻 Tick、细节等级、数据新鲜度/失效规则、请求 ID。没有变化或观察失败也可合理消耗点数，以保留无效操作和信息维护成本。

## 5. 命令反馈规则

内部结果与对 AI 可见结果分离：

- 系统内部保留完整 `CommandResult` 和 DomainEvent，用于一致性、日志、回放与自动化测试；
- 大模型立即获知协议错误、认证失败或操作点不足；
- 单位是否真实执行、目标是否存在、建筑是否完成等世界内事实，默认不直接推送；
- 需要这些事实时，大模型再次消耗操作点观察；
- 面向玩家的 UI/语音可以订阅经过玩家可见性策略过滤的事件，例如“建造完成”。

错误码也可能成为战争迷雾侧信道。例如对不可见 UnitId 返回 `UnitNotFound` 或 `UnitNotOwned`，可能泄漏隐藏单位是否存在。因此跨语言协议应返回过滤后的通用结果，原始错误只留在服务端诊断记录中。

## 6. 结构化控制与像素控制

建议默认使用“结构化命令 + 受限观察”：它能准确计费、便于测试，也不会把 AI 接口绑定到临时 UI。若玩法或研究目标确实要求模拟真人鼠标、镜头和视觉识别，可另建 Pixel Controller Adapter；两者共享操作点预算，但像素控制不成为领域层依赖。

## 7. 当前重构的预留项

- `CommandContext` 未来增加 ControllerId/CommandSource 审计字段；
- 命令结果与 Presentation 解耦，不直接生成玩家文字或 AI 文本；
- DomainEvent 经反馈/观察策略后再对控制器发布；
- Python 只连接版本化 DTO/协议，不访问 Godot Node；
- 操作点、观察 DTO、事件订阅和跨语言传输方式均需后续独立评审，本轮不编码。
