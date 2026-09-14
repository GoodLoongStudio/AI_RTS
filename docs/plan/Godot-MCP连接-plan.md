# Godot MCP 连接 Implementation Plan

## Overview
给 Cursor 配上仓库自带的 Godot MCP Native，以便运行项目并查看画面。

## Current State Analysis
`addons/godot_mcp` 已启用，默认 HTTP 端口 9080。Cursor 这边还没有项目级 MCP 连接器。

## Implementation Strategy
写 `.cursor/mcp.json` 指向本地 `http://127.0.0.1:9080/mcp`，并加一条规则提醒后续会话使用 `run_project` / 运行时截图。

## Implementation Steps
1. ✅ 项目 MCP 配置
2. ✅ 会话规则
3. ✅ Cursor 已连上 `godot-mcp`（30 tools）

## Timeline
只配连接，不改玩法代码。

## Risk Assessment
必须先开 Godot 编辑器；端口被占用或未点启动时，Cursor 连不上。

## Success Criteria
- Cursor MCP 列表出现 `godot-mcp`
- 能 `run_project` 并拿到运行时截图

## Progress Tracking
✅ 配置文件
✅ Cursor 已连通

## Related Files
- `.cursor/mcp.json`
- `.cursor/rules/godot-mcp.mdc`
- `addons/godot_mcp/`
