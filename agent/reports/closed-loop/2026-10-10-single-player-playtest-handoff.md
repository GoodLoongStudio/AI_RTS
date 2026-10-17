# 单人房试玩提示词交付记录

日期：2026-10-10（北京时间）。状态：文档交付；实际试玩和问题发现待 DeepSeek 执行。

## 本轮交付

- [执行提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-10-deepseek-single-player-playtest.md)
- [配套计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-10-single-player-playtest-plan.md)
- 本交付记录。

用户本轮要求是写提示词，让 DeepSeek 开单人房模拟玩家，把遇到的问题列为 Markdown；不是让我现在试玩或修复游戏。提示词明确只审计、不修改产品，先真实菜单纯单人，再单机对简单 AI，再退局换图重开复验。问题报告由执行者创建，文件名包含实际执行日期和唯一 run-id。

## 设计核验

已读取仓库入口、workspace boundaries、manifest、闭环工作法、RSI、MCP 说明、实例工具入口和单机菜单源码。

静态核验显示：`Play.gd` 单机开始走本机 `NetSession.host` 和 Loading 链路；槽位配置支持只保留一名人类，纯单人练习不自动判胜负。提示词不把本地服务器对象或无胜利弹窗误报 BUG，也不以 server+client 自动开局替代玩家单机菜单验证。

报告合同包括严重度、玩家操作步骤、预期/实际、截图/日志/数据、复现次数/尝试次数、证据状态、覆盖/未测项目、工具与游戏问题分离、退出码和 `cleanup_ok`。无头只能补充逻辑重放，不能证明 UI、视觉和玩家画面性能。禁止作弊/刷钱补覆盖，禁止边试玩边改产品掩盖原始问题。

## 文档验证

- Git 根核验 rc=0，为 `G:/AIRTS/AI_RTS`。
- 三份文档创建前分别运行 `check_workspace_target.py --mode develop --target <绝对路径>`，均 rc=0。
- 计划/提示词的严格 UTF-8、非空、代码围栏、链接目标、关键合同字段和 9 个依赖文件存在检查 rc=0，输出 `PLAYTEST_PROMPT_VALIDATED`。
- 针对计划/提示词的 `git diff --check` rc=0；新文件尚未跟踪，因此另外直接校验内容，不用空 diff 当唯一证明。

## 未运行与共享风险

本轮未启动游戏、未开单人房、未模拟玩家、未生成玩法截图、未运行 C# 构建或游戏回归；没有本轮实测 BUG、FPS 或修复结果。文档类交付按 RSI 例外不要求实际 Match，不能把本记录当试玩完成。

工作区检查时有 955 条状态记录，全部保留。本轮写入仅三份 Markdown。补订期间的源码保护复查 rc=1，发现 Movement hash 已被外部修改；没有写入或恢复该脚本。提示词要求接手与每局取证时重新核对版本，不能将跨版本数据混为当前结论。未清理他人进程、未更新成品或 GitHub release，未晋级产品 candidate/champion。
