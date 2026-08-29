# Godot MCP 集成说明

## 文档信息

- 事项 ID：DEV-20260811-005
- 状态：已实现，待 Pull Request 评审
- 日期：2026-08-11
- 适用引擎：Godot 4.x
- 插件：Godot MCP Native `1.0.7-pre1`

## 目的

为程序协作者提供受控的 Godot 编辑器访问能力，用于读取项目状态、检查场景和脚本、启动测试以及在明确授权后执行编辑操作。该工具不改变团队的职责边界，也不授权程序对美术风格、世界观或剧情作出决策。

## 仓库改动

- 添加 `addons/godot_mcp/` 插件源码。
- 在 `project.godot` 中启用 `res://addons/godot_mcp/plugin.cfg`。
- 注册 `MCPRuntimeProbe` 自动加载脚本，以支持运行时检查。
- 修复 Runtime Probe 使用未声明自身类型名导致的 Godot 4.7 解析错误；删除保护改为与 `self` 比较。

## 本地连接

工作区 `.cursor/mcp.json` 已注册两个端点。必须先打开对应 Godot 编辑器，MCP 才会监听。

| 工程 | 端口 | Cursor 服务器名 | 启动脚本 |
|---|---|---|---|
| `AI_RTS` | 9080 | `godot-airts` | `tools/start-godot-airts-mcp.bat` |
| `godot-rts-terrain` | 9081 | `godot-rts-terrain` | `tools/start-godot-rts-terrain-mcp.bat` |

```text
http://127.0.0.1:9080/mcp
http://127.0.0.1:9081/mcp
```

两个工程可以同时开编辑器；不要都占用 9080。本机 `mcp_settings.cfg` 已设 `auto_start=true`。认证令牌、外网地址或其他凭据不得提交到仓库。需要远程访问时，必须单独进行安全评审并启用认证。

## 验证记录

在 Godot `4.7.stable.mono` 上完成以下检查：

1. MCP `initialize` 握手成功，协议版本为 `2025-03-26`。
2. 可以读取项目信息、编辑器状态、当前场景及编辑器日志。
3. 可以通过 MCP 启动 `res://source/Main.tscn`，并正常停止运行。
4. 主场景启动使用 Vulkan Forward+；基础启动期间未观察到游戏脚本错误。
5. Runtime Probe 修复后重新加载成功；再次启动活动场景时 MCP 返回 `probe_ready=true`，随后正常停止运行。

## 协作约束

- 默认优先使用只读 MCP 工具。
- 写场景、改节点、改脚本或运行窗口前，必须有明确任务授权。
- MCP 产生的改动与普通代码改动遵循相同的分支、评审和测试流程。
- 不提交 `.godot/`、生成的 `*.translation`、认证令牌或本地编辑器状态。
- 提交前检查 Godot 自动生成的 `.import` 差异，避免把无关重新导入结果混入功能提交。

## 回退方式

如需停用集成：

1. 在 Godot 的“项目设置 → 插件”中禁用 Godot MCP Native。
2. 从 `project.godot` 的 `[editor_plugins]` 中移除插件条目。
3. 从 `[autoload]` 中移除 `MCPRuntimeProbe`。
4. 删除 `addons/godot_mcp/`。
