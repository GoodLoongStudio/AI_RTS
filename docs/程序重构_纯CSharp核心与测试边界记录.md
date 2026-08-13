# 程序重构：纯 C# 核心与测试边界记录

日期：2026-08-14

对应进度：`ARCH-009`、`ARCH-010`、`ARCH-011`

## 1. 目标

证明 Domain/Application 的命令规则可以在不启动 Godot、不实例化场景且不加载 Godot 程序集的情况下编译和执行，并明确核心规则与 Godot/Legacy 执行层的程序集边界。

## 2. 工程边界

新增 `AI_RTS.Core.csproj`，仅编译：

- `source/csharp/Domain/**/*.cs`；
- `source/csharp/Application/**/*.cs`。

Godot 主项目 `OpenRTS.csproj` 改为：

- 显式编译 `source/csharp/GodotAdapter/**/*.cs`；
- 显式编译 `tests/automated/**/*.cs` 中的 Godot 集成测试；
- 通过 `ProjectReference` 引用 `AI_RTS.Core`；
- 不再依赖根目录默认 `**/*.cs` 通配收集，避免把其他测试项目的 `obj` 中间代码错误编入 Godot 程序集。

允许的迁移期依赖方向为：

```text
OpenRTS / GodotAdapter → AI_RTS.Core
OpenRTS / GodotAdapter → Legacy GDScript
```

禁止：

```text
AI_RTS.Core → Godot
AI_RTS.Core → Legacy GDScript
```

代码扫描确认 Domain/Application 中没有 `Godot`、`Node`、`Vector3`、`NavigationAgent3D` 或 `NavigationServer3D` 类型。导航和攻击算法仍可由 Legacy 适配器执行，但只能通过 `IUnitMovementPort`、`IUnitAttackPort` 等 Application 端口进入。

## 3. 纯 C# 测试入口

新增 `tests/core/AI_RTS.Core.Tests.csproj`。该项目为普通 `net8.0` 控制台程序，不引用 Godot SDK，也不引入第三方测试框架和网络包。

运行命令：

```powershell
dotnet run --project tests/core/AI_RTS.Core.Tests.csproj
```

失败时返回非零进程退出码，适合本地检查和后续 CI。

## 4. 当前覆盖

纯 C# 测试共 11 项：

1. 多单位部分成功和逐单位错误；
2. 重复单位 ID 去重；
3. 非有限目标坐标拒绝且不调用导航端口；
4. 新端口请求失败时保留旧活动订单；
5. Halt 将移动订单转换为 `Suspended`；
6. 姿态、开火策略正交保存及所有权检查；
7. 普通攻击受停火限制；
8. ForceAttack 临时覆盖停火但不修改持续策略；
9. 停火时 AttackMove 仍保留移动意图；
10. 无倒车能力单位的撤退执行退化；
11. Godot/Legacy 端口错误映射为稳定 Application 错误码。

测试结果：11 项通过，0 项失败。

## 5. 构建验证

- `dotnet run --project tests/core/AI_RTS.Core.Tests.csproj`：11 tests，0 failures；
- `dotnet build OpenRTS.csproj --no-restore`：0 warning，0 error；
- Godot 无头运行 `CSharpCommandSmokeTest.tscn`：0 failure，进程退出码 0；
- `git diff --check`：通过；
- 核心代码 Godot 类型扫描：无匹配。

## 6. 当前边界

本次完成的是核心程序集与依赖方向解耦，不表示 Legacy 执行层已经迁移完成。现有 Tank 仍可能通过 GodotAdapter 调用 GDScript 移动和攻击行为；未来替换导航、战斗或 Python 连接实现时，只需替换端口实现，不应修改核心命令契约及其纯 C# 测试。

Godot 场景中的 `CSharpCommandSmokeTest` 暂时保留，继续承担 Godot 能正确加载核心程序集的集成冒烟职责。纯 C# 测试负责规则，Godot 测试负责装配、场景、Signal 和生命周期，两者不互相替代。
