# 程序重构：传统控制组 C# 服务接口评审稿

> 对应进度：`CMD-021`、`AIFR-011`
>
> 本轮只评审旧项目已有的 `Ctrl+1..9` 保存与 `1..9` 访问行为，不实现 Formation、AI Squad、镜头双击定位或新增组合键。

## 1. 当前问题

`UnitGroupSelectionHandler.gd` 已经通过集中式 `InputBindingRuntime` 接收按键动作，但控制组成员仍保存在 Godot SceneTree 的 `unit_group_1..9` 动态组中：

- 没有 C# 服务或稳定快照；
- 没有显式玩家身份、对局身份或错误结果；
- 单位死亡只能依赖 SceneTree 自动消失，无法形成可测试的清理语义；
- Legacy `AICommandHUD.gd` 和 `CampaignController.gd` 也读取或写入同名组，使玩家 `ControlGroup` 与 AI/Campaign Squad 继续共用状态；
- 未来 Formation、Agent 编组或回放功能容易误把节点组当作领域概念。

新输入服务解决的是“哪个 ActionId 被触发”，没有解决“控制组保存什么、属于谁、何时失效”。因此当前功能可用，但 `CMD-021` 尚未完成。

## 2. 概念边界

| 概念 | 含义 | 生命周期 | 是否下达命令 |
|---|---|---|---|
| Selection | 玩家此刻选中的实体集合 | 短暂、本地 | 否 |
| ControlGroup | 玩家给己方实体保存的 1～9 编号集合 | 当前对局、本地 | 否 |
| Formation | 一次或持续移动中的空间槽位关系 | 命令/订单相关 | 可以影响移动目标 |
| AI Squad/Battlegroup | AI 策略内部的战术成员集合 | AI 策略决定 | AI 可据此提交公共命令 |

ControlGroup 只负责保存和返回成员身份。保存、访问均不得：

- 自动移动单位；
- 修改 EngagementStance 或 FirePolicy；
- 建立 Formation；
- 改写 AI Squad/Battlegroup；
- 改变单位生产、施工、采集或其他活动订单。

## 3. 建议 C# 契约

### 3.1 值对象

```csharp
public readonly record struct ControlGroupNumber(int Value);
```

- 首版只允许 `1..9`；
- 非法编号在进入存储前稳定拒绝；
- 数字键绑定仍由 `IInputBindingService` 管理，服务不读取物理键盘。

控制组由当前 Match 内的 `PlayerId + ControlGroupNumber` 唯一确定。服务实例本身也由 Match 组合根创建，跨对局 UnitId 不得进入新对局。

### 3.2 服务接口

```csharp
public interface IControlGroupService
{
    ControlGroupSaveResult Replace(
        PlayerId playerId,
        ControlGroupNumber group,
        IReadOnlyList<UnitId> selectedUnitIds);

    ControlGroupRecallResult Recall(
        PlayerId playerId,
        ControlGroupNumber group);

    ControlGroupSnapshot Inspect(
        PlayerId playerId,
        ControlGroupNumber group);

    void RemoveUnit(UnitId unitId);
}
```

- `Replace` 对应 `Ctrl+数字`，永远替换而非追加；
- `Recall` 返回当前仍有效、仍归属该玩家且可选择的成员，并惰性清理无效项；
- `Inspect` 供 UI、测试和诊断读取，不触发 Selection；
- `RemoveUnit` 由 Godot 生命周期 Adapter 在单位退出时主动调用；`Recall` 仍必须复验，防止漏掉退出事件；
- 首版不提供追加、删除单个成员、跨组复制、持久化到磁盘或跨对局导入。

### 3.3 单位读取端口

Application 服务不能读取 Godot Node 或 SceneTree，建议依赖：

```csharp
public interface IControlGroupUnitRepository
{
    ControlGroupUnitSnapshot? Find(UnitId unitId);
}

public sealed record ControlGroupUnitSnapshot(
    UnitId UnitId,
    PlayerId OwnerPlayerId,
    bool Selectable);
```

Godot Adapter 可以复用当前稳定身份和弱引用注册表，但 `IControlGroupService` 不得依赖 `Node`、节点组、脚本路径或 `Selection.gd`。

## 4. 保存语义

建议 `Replace` 使用以下规则：

1. 编号非法时整次拒绝，原控制组保持不变；
2. 输入 UnitId 去重；同一单位允许同时属于多个不同控制组；
3. 仍存在、属于发出玩家且可选择的实体进入新集合；
4. 已死亡、未知、敌方或不可选择实体返回逐项拒绝，不进入集合；
5. 至少一个成员有效且至少一个无效时返回 `PartiallyAccepted`；
6. 输入非空但没有任何有效成员时返回 `Rejected`，保留原组，避免一次生命周期竞争意外清空已有组；
7. 输入显式为空时返回 `Accepted` 并清空该组，这是玩家主动执行 `Ctrl+数字` 保存空 Selection 的结果；
8. 成员快照按 UnitId 稳定排序，不把 Selection 顺序解释为主单位或 Formation 顺序。

建议返回：

```csharp
public sealed record ControlGroupMemberResult(
    UnitId UnitId,
    bool Accepted,
    ControlGroupErrorCode ErrorCode);

public sealed record ControlGroupSaveResult(
    ControlGroupStatus Status,
    ControlGroupNumber Group,
    IReadOnlyList<UnitId> StoredUnitIds,
    IReadOnlyList<ControlGroupMemberResult> MemberResults);
```

错误码首版包含：

- `None`；
- `InvalidGroup`；
- `UnitUnavailable`；
- `UnitNotOwned`；
- `UnitNotSelectable`。

错误差异只涉及玩家试图保存的本地己方选择输入，不提供敌军远程探测入口。

## 5. 访问语义

建议 `Recall` 使用以下规则：

1. 编号非法时拒绝且不改变当前 Selection；
2. 读取保存集合后，再次检查存活、归属和可选择性；
3. 失效成员从存储中永久剔除，并在结果中返回 `PrunedUnitIds` 供测试/诊断；
4. 至少一个有效成员时返回 `Accepted` 和稳定 UnitId 集合；Godot Adapter 用它替换当前 Selection；
5. 组从未保存、已被清空或成员全部失效时，返回 `Accepted`、`UnitIds = []` 和显式 `IsEmpty = true`；
6. 访问空组不清空玩家当前 Selection，也不播放失败反馈。这保持当前旧项目行为和常见 RTS 操作习惯；
7. 首版不实现 `Shift+数字` 追加访问，也不实现双击数字让镜头聚焦。

`Recall` 的成功空结果不能用 `null` 或缺失键表示，以便自动测试和未来 UI 区分“空组”与“服务错误”。

## 6. Godot Adapter 与装配

建议新增 Match 级 `ControlGroupRuntime`：

- 与 `CommandRuntime`、`InputBindingRuntime` 同属每局唯一 Runtime；
- 由可信 Match 组合根绑定本地 Human 的 `PlayerId`；普通调用方不能传入任意玩家身份；
- 监听既有 `group.set_1..9`、`group.access_1..9` ActionId；
- 保存时读取当前 `selected_units` 中属于本地 Human 的 Node，将其转换为稳定 UnitId 后调用 `Replace`；
- 访问时按返回 UnitId 解析仍有效 Node，再调用 Godot Selection 表现；
- 单位退出时主动调用 `RemoveUnit`；
- 不创建或读取 `unit_group_N` SceneTree 组。

迁移后删除 `UnitGroupSelectionHandler.gd/.tscn` 在 Match 中的装配。为了避免一次性修改大量场景，Match 中原节点名可以保留，但脚本和类型应切换为 C# Runtime。

## 7. 与 Legacy AI HUD 和战役的隔离

传统 ControlGroup 迁移后不再维护 `unit_group_N` 兼容镜像，否则两个概念仍然共享状态，迁移没有完成。

建议在同一纵向切片完成：

- `AICommandHUD` 不再从玩家 ControlGroup 取得 Squad；
- 战役暂时需要的固定小队改用明确的 `legacy_ai_squad_N` 表现组，直到战役专项迁移；
- 自定义对局中未由任务系统建立的 AI Squad 可以为空；冻结 HUD 不再提示玩家用 `Ctrl+数字` 建立 AI Squad；
- Legacy HUD 的 Stop/Defend 若继续可触发，必须调用公共命令/策略 Gateway；否则在冻结期禁用按钮并返回明确提示；
- 任务进度 Signal 可以暂留，但不能把“按钮已点击”当作单位命令已经成功的证明。

## 8. 测试与验收

### 8.1 纯 C#

- 保存、覆盖、清空和访问 1～9；
- 同组输入去重、跨组重复允许；
- 敌方、未知、不可选择和已死亡成员结果；
- 非空全无效保存不会清空原组；
- 部分成功保存；
- 退出事件主动清理与 Recall 二次惰性清理；
- 玩家之间同编号完全隔离；
- 成员返回顺序确定。

### 8.2 Godot 冒烟

- `Ctrl+1` 保存、`1` 替换召回；
- 保存空 Selection 清组，访问空组保持当前 Selection；
- 单位死亡后访问不会返回失效 Node；
- 建筑和移动单位都可以保存；
- 敌方单位不能通过 Adapter 进入玩家控制组；
- Match 中不再新增 `unit_group_N`；
- AI HUD 显示/隐藏与控制组按键互不影响。

### 8.3 人工验收

- 保持项目负责人此前确认的 `Ctrl+1` 保存和 `1` 访问体验；
- 连续覆盖、跨多个编号保存和单位死亡后的召回无明显错误；
- 控制组操作不改变单位姿态、任务或移动队形；
- AI 副官 HUD 不再把玩家控制组显示为作战小队。

## 9. 本轮非目标

- Formation、列队、散开和多单位导航；
- 控制组 UI 列表、成员头像、改名和持久化；
- `Shift+数字`、`Alt+数字`、双击数字镜头聚焦；
- AI Squad/Battlegroup 的策略细化；
- 战役强类型任务和英雄控制；
- 联机同步、回放序列化或存档格式。

## 10. 待项目负责人确认

1. 是否接受“空选择保存会清空组；访问空组保持当前 Selection”；
2. 是否接受非空输入全无效时拒绝并保留原组，而不是清空；
3. 是否接受有效与失效混合时部分成功，并用有效成员替换原组；
4. 是否接受单位可同时属于多个控制组；
5. 是否接受召回时剔除死亡、失去归属或不可选择成员；
6. 是否接受首版成员按稳定 UnitId 排序，不保存 Selection/Formation 顺序；
7. 是否接受传统控制组不维护 `unit_group_N` 兼容镜像，并将冻结战役小队临时改名为 `legacy_ai_squad_N`；
8. 是否接受首版不增加 Shift/Alt 访问、镜头聚焦和控制组 UI。
