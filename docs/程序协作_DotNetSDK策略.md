# 程序协作：.NET SDK 策略

> 对应进度：`BASE-011`
>
> 日期：2026-08-15

## 1. 统一结论

仓库根目录通过 `global.json` 要求：

- 最低 SDK：`.NET SDK 8.0.423`；
- 滚动策略：`latestFeature`；
- 禁止使用 Preview SDK；
- `OpenRTS`、`AI_RTS.Core` 和 `AI_RTS.Core.Tests` 均继续以 `net8.0` 为目标框架。

`latestFeature` 允许使用已安装的、不低于 `8.0.423` 的最高 .NET 8 feature band 或补丁版本，但不会自动滚动到 .NET 9、10 或后续主版本。这使团队可以及时安装 .NET 8 安全补丁，同时避免成员因不同主版本 SDK、编译器或分析器产生不一致结果。

## 2. 选择依据

- Godot C# 项目需要单独安装 .NET SDK；仅安装 .NET Runtime 不足以编译项目；
- 当前三个 C# 项目都明确使用 `net8.0`；
- 2026-08-15 核对时，微软提供的最新 .NET 8 SDK 为 `8.0.423`；
- 本机虽然已有 .NET 8 Runtime，但只有 .NET 10 SDK。Runtime 不能代替 SDK；加入 `global.json` 后必须另外安装合规的 .NET 8 SDK。

官方依据：

- Godot C# 前置要求：https://docs.godotengine.org/en/4.7/tutorials/scripting/c_sharp/c_sharp_basics.html
- `global.json` 与 `latestFeature` 语义：https://learn.microsoft.com/dotnet/core/tools/global-json
- .NET 8 SDK 下载：https://dotnet.microsoft.com/download/dotnet/8.0

## 3. 开发机安装与检查

Windows x64 开发机应安装完整的 `.NET 8 SDK x64`，不是只安装 Runtime。可以使用微软安装器，或执行：

```powershell
winget install Microsoft.DotNet.SDK.8
```

如果开发机没有 `winget`，使用微软官方 Windows x64 安装器：

https://dotnet.microsoft.com/download/dotnet/thank-you/sdk-8.0.423-windows-x64-installer

安装后关闭并重新打开终端与 Godot，再从仓库根目录验证：

```powershell
dotnet --list-sdks
dotnet --version
dotnet build .\OpenRTS.csproj
dotnet run --project .\tests\core\AI_RTS.Core.Tests.csproj
```

预期 `dotnet --version` 返回 `8.0.423` 或更高的 `8.0.x`。如果只安装了 .NET 9/10，命令应明确失败，提醒成员安装团队规定的 SDK，而不是静默使用其他主版本。

## 4. CI 约束

`.github/workflows/dotnet-core.yml` 使用 `actions/setup-dotnet` 读取仓库根目录的 `global.json`，随后构建 `OpenRTS.csproj` 并运行纯 C# 核心测试。向 `main` 提交 Pull Request、推送 `main` 或手动触发时都会执行。

本地能够构建不等于可以绕过 CI。SDK 策略、Godot SDK 包、项目目标框架和测试必须同时通过。

## 5. 升级规则

安全补丁和新的 .NET 8 feature band 可由 `latestFeature` 自动采用，不需要每次修改仓库。

以下变化必须建立独立需求分支并评审：

- 将最低 SDK 提高到新的版本；
- 将目标框架从 `net8.0` 升级到其他版本；
- 允许新的 .NET 主版本 SDK；
- 升级 `Godot.NET.Sdk` 或 Godot 引擎主/次版本；
- 引入依赖特定 SDK、语言版本或运行时的跨语言、数据库和网络组件。

评审至少应记录 Godot 兼容性、开发机与 CI 环境、导出平台、第三方包、全量测试和回退方案。不得只修改 `global.json` 而不检查项目目标框架及 Godot 版本。

## 6. 本机实施记录

2026-08-15：仓库约束建立后，已验证只有 .NET 10 SDK 时，`dotnet` 会明确报告缺少 `8.0.423`，不会静默使用 .NET 10。自动安装到系统目录因缺少管理员权限被拒绝；随后尝试的当前用户安装在下载阶段长时间无响应，已安全终止且未留下不完整 SDK 或永久环境变量。

项目负责人之后通过微软官方 Windows x64 安装器完成 `.NET SDK 8.0.423` 安装。验收结果：

- `dotnet --list-sdks` 同时显示 `8.0.423` 与 `10.0.301`；
- 在仓库根目录执行 `dotnet --version`，`global.json` 正确选择 `8.0.423`；
- `OpenRTS.csproj` 构建成功，0 警告、0 错误；
- 101 项纯 C# 核心测试全部通过；
- Legacy GDScript 权威审计扫描 128 个文件、61 处已登记写入，未知旁路为零。

BASE-011 已完成。Godot 若在安装前已经启动，应重启一次，使编辑器及其子进程继承最新 SDK 环境。
