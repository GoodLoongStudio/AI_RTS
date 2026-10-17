# MCP Map

项目已经有 Godot MCP，但它不是一个“随便启动多个 Godot 就行”的黑盒。Agent 使用前先确认当前实例和端口。

| 能力 | 项目位置 | 说明 |
|---|---|---|
| Godot MCP HTTP | `addons/godot_mcp/` | 编辑器/运行时截图、启动项目和调试工具；Cursor 连接配置在 `.cursor/mcp.json`，默认地址 `http://127.0.0.1:9080/mcp` |
| 运行时交互 | `autoload/mcp_interaction_server.gd` | 对局内交互入口，具体端口以启动日志为准 |
| 调试控制 | `source/net/DebugControlServer.gd` | 通过 `--debugport` 显式传入测试端口，避免并行 Agent 抢端口 |
| 调试规则 | `.cursor/rules/godot-mcp.mdc` | 已有的 Godot MCP 使用说明 |

DeepSeek Harness 或其他 Agent 不应复制一份假的 MCP 服务配置。先读取本文件和 `.cursor/rules/godot-mcp.mdc`，探测端点是否已被当前 Godot 实例占用，再决定复用还是启动独立测试实例。

截图证据的原始文件放 `agent/runs/<run-id>/screenshots/`；长期报告只引用这些路径或复制一份经过筛选的关键图。
