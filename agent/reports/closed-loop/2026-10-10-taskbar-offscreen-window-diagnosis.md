# 点击任务栏 Godot 图标没有画面：当前实例诊断

日期：2026-10-10，北京时间。开发根 `G:/AIRTS/AI_RTS`。状态：屏外窗口原因已确认；用户要求恢复的原窗口随后退出，未能恢复，不宣称已修复或已展示。

## 原因和证据

最初检查时只发现一个 Godot 运行实例，没有 Godot 编辑器进程。它由当前后台试玩驱动启动，不是用户新开的独立手动实例。

| 项目 | 实测 |
|---|---|
| 游戏 PID / 父 PID | `39120 / 51160` |
| 窗口 HWND / 标题 | `1247874 / Open RTS (DEBUG)` |
| 创建时间 | `2026-10-10 18:20:30` |
| 响应/可见/最小化/前台 | `true / true / false / false` |
| 外框矩形 | `left=-4000, top=-4000, right=-2219, bottom=-2968`，完全屏外 |
| 命令行 | Godot 4.7.1 Mono，`--path G:\AIRTS\AI_RTS --windowed --audio-driver Dummy --position -4000,-4000`，日志归属本轮后台试玩 |

[实例身份](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/identity.json) 与进程匹配。[驱动](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/drive.py) 的启动参数带屏外位置，且就绪后用 `SetWindowPos` 将该 HWND 放至 `(-4000,-4000)`，采用底层/不激活。其 background 操作会再次放屏外；未见无条件循环每帧搬走。

因此在任务栏激活这扇窗口不等于把它移回显示器，解释了用户当时的现象。不能据此断言所有手动启动都坏了，也没有证据表明工程设置被永久改为屏外。

## 用户请求与实际执行

用户明确选择“把当前测试窗口移回屏幕，只查看”。准备执行一次 `SWP_NOSIZE|SWP_NOACTIVATE|SWP_SHOWWINDOW` 移回主显示器工作区，先核验 PID/命令行/HWND。`Get-Process -Id 39120` 已找不到进程，命令 rc=1，**尚未调用 SetWindowPos，也未发送任何输入/关闭/终止指令**。

后续进程快照无 Godot。[清理记录](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/cleanup.json) mtime `18:31:31`，记录 `game_rc=1, cleanup_ok=true, window_close=false, normal_menu_exit_verified=false`。这是他方驱动记录，不是本会话清理。退出原因 unknown；日志尾部有 AI ResourceDepleted 警告，但没有证据可将其确定为退出根因，更不能与原始屏外显示问题合并。

最后保存的 [clip-B02 录像](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/video/clip-B02.mp4) 为历史片段，非实时窗口。[元数据](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/video/clip-B02.json) 记录本地时间约 `18:28:35-18:29:10`、35 秒、175 帧、6 补帧、status=partial，因 hidden/minimized 中断；不能作为完整动态验收。这与后来的进程退出是不同事件。

## 检查及范围

- Git 根核验 rc=0；两份诊断文档编辑目标 workspace check 均 rc=0。
- 进程/CIM 查询、Win32 矩形读取和驱动/身份/退出记录读取均完成；用户附件仅显示任务栏，不证明工程没启动。
- 只新增本 [计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-10-taskbar-offscreen-window-diagnosis.md) 和报告，严格 UTF-8/链接/围栏/空白检查 rc=0。
- 未修改游戏、默认设置、其他 Agent 驱动/证据、技能、成品或发布；未结束进程，未开新局冒充原局，未运行玩法回归或新截图/录像。
- 抽查 `project.godot`、`Movement.gd`、`DebugControlServer.gd` SHA256 与上轮提示词任务记录一致；共享树有 956 个既有状态条目，不能据抽查声称整树冻结。

## 后续建议

后台实例应明确标注测试身份，且用户主动要求查看时应有 show/background 的成对控制；用户手动工程和测试实例应隔离。显示控制不能自动反复抢前台，也不能把后台原则误用为用户永远不能查看窗口。当前运行驱动尚无 show 分支，本次未擅改。需要新对局或协调 DeepSeek 时另按用户授权处理。
