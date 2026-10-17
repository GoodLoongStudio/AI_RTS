# 后台录像试玩计划（20261010-background-playtest-01）

- 日期：2026-10-10；提示词：`agent/prompts/deepseek-background-video-playtest.md`
- 工程：`G:/AIRTS/AI_RTS`；commit：`9a2e6d4`；OpenRTS.dll SHA256 前 16：`41F23C3907E38A43`（mtime 2026-10-09 23:38:45，试玩开始前既有产物）
- 模式：**非干扰后台**——辅助进程 CREATE_NO_WINDOW 隐藏启动；游戏窗口屏外+底层+不激活；禁止 OS 级输入（SendInput/mouse_event/SendKeys/SetCursorPos）与 warp_mouse；不抢焦点、不置顶、不恢复最小化。
- 输入通道：MCP `mcp_interaction_server.gd`（引擎内事件，`process_mode=ALWAYS` 暂停可用；click 无 warp；端口/token 环境变量注入 + get_instance_info 核验 PID）＋ DCS `op=key`（键盘，引擎内合成）＋ command-level op（move/build/produce/gather，仅注明 command-level 的项目）。
- 已知输入资格预期（须实测）：框选/修饰键编组无引擎内实现→预计 blocked；持续镜头按键待测。

## 阶段

1. [ ] 工具资格门禁：启动非干扰实例（动态端口/登记/屏外窗口）→ 录制器 15-30s 短测（后台画面连续变化）→ MCP click 点选单位验证真实反馈（选中面板/位置变化）→ 右键移动 → Esc 菜单/恢复。
2. [ ] A 局（纯单人，5-10 分钟）：菜单开房→探索→合法建造→矿车两趟→产兵→移动→菜单退局。全程 5 FPS 分段录制。
3. [ ] B 局（对简单 AI，10-20 分钟）：加 AI→发展→出兵→探索接敌→攻击/损伤→撤退；录像+状态采样。
4. [ ] C 局：菜单退局换图重开，残留检查；P0/P1 最小步骤复现。
5. [ ] 回看：所有 clip 按 0.2s（5FPS）/0.1s（10FPS）实际打开联系表与关键帧，写 review.md。
6. [ ] 报告：问题总表（含时间码）、覆盖表（pass/failed/blocked/untested/not-applicable + 证据等级）、cleanup。

## 非干扰红线（全程）

- 不 SetForegroundWindow / 不置顶 / 不恢复窗口 / 不移动光标 / 不发 OS 输入；用户切窗口不算游戏故障。
- 录制 PrintWindow 仅采本轮窗口客户区；`--method screen` 禁用（无用户独占授权）。
- 证据等级分层：UI-synthetic / command-level / headless / log-only；`Accepted` 不等于玩家路径通过。
- 游戏窗口可能被用户遮挡或最小化：属测量条件，不归为游戏故障；恢复操作禁止。

## 产物

- 计划：本文件。
- 报告：`agent/reports/closed-loop/2026-10-10-background-playtest-issues-20261010-background-playtest-01.md`。
- 证据：`agent/runs/20261010-background-playtest-01/`（video/review/states/logs/screenshots/cleanup）。
