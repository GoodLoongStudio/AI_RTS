# 程序开发：C# 编码规范

> 状态：项目负责人已确认，自 2026-08-12 起适用于本项目新增和修改的 C# 代码

## 1. 文档注释

- 类、record、struct、interface 和 enum 必须使用 `///` XML 文档注释说明职责；
- 有实际功能的方法必须使用 XML 文档注释，说明行为、语义或关键边界；
- 实现已注释接口的方法可以使用 `/// <inheritdoc />`；
- 仅用于构造 DTO、简单类型转换、属性转发或无业务语义的薄封装方法可以不添加注释；
- 注释建议使用中文；类名、方法名、API、Guid、DTO、RTS、AI 等关键字、专业名词与缩写可保留英文；
- 注释应解释职责、约束、状态变化或失败语义，避免只把标识符逐字翻译成中文；
- 重要字段和属性需要注释，尤其是配置、缓存、索引、生命周期状态和跨层引用。

示例：

```csharp
/// <summary>协调单位校验、导航端口调用与订单状态更新。</summary>
public sealed class UnitCommandService : IUnitCommandService
{
    /// <summary>停止单位当前移动，并将已有活动订单转为暂停。</summary>
    public CommandResult HaltMovement(...)
    {
        // ...
    }
}
```

## 2. 枚举与配置字段

- enum 本身和每一个枚举项都必须添加中文 XML 注释；
- 数值管理类、按键管理类、配置 DTO、错误码和状态类中的公开字段/属性必须说明单位、范围、默认语义或用途；
- 时间、距离、速度、百分比、Tick、操作点等数值必须在注释或类型中明确单位；
- 不使用无说明的裸数字表达业务规则；常量需要语义化命名和注释。

## 3. 控制语句

`if`、`else`、`for`、`foreach`、`while`、`do` 等控制语句必须使用大括号，即使代码块只有一行。禁止：

```csharp
if (unit is null)
    return;
```

应写为：

```csharp
if (unit is null)
{
    return;
}
```

此规则同样适用于测试代码。lambda 表达式和 switch expression 不属于省略控制语句大括号的情况。

仓库根目录 `.editorconfig` 已将 `csharp_prefer_braces = true:error` 作为编辑器和格式化工具的自动约束；代码评审仍需检查生成代码之外的实际源文件。

## 4. 检查要求

每次 C# 修改至少执行：

1. 检查新增/修改类型、功能方法、枚举项和重要字段的 XML 注释；
2. 检查控制语句大括号；
3. `dotnet build`，要求 0 error；
4. 运行与改动相关的自动化测试；
5. `git diff --check`。

现有 GDScript 不要求一次性套用 C# 注释格式；迁移为 C# 时必须遵守本规范。
