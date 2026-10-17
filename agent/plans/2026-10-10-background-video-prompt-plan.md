# DeepSeek 后台录像试玩提示词重写计划

日期：2026-10-10。范围：文档交接，不启动新对局、不修产品或录制工具。

## 目标与基线

让 DeepSeek 以后在用户继续聊天和使用电脑时进行后台试玩，通过连续录像、动作时间线、状态数据及实际回看记录问题。旧提示词仍有原生输入 fallback，纠正提示词的工具验证口径落后于真实 Godot 烟测；必须消除冲突，不把历史烟测当新一轮试玩。

## Checklist

- [x] 读取仓库契约、workspace boundaries、manifest、闭环/RSI、temporal skill 和已有试玩文件。
- [x] 核对 Git 根、共享工作树状态、目标 mtime；六个编辑目标路径检查 rc=0。
- [x] 创建可独立转发的常驻提示词，包含非干扰门禁、输入资格、录制/回看、覆盖和报告合同。
- [x] 更新旧提示词入口、移除原生输入自动 fallback；纠正旧工具验证表述。
- [x] 在现有 temporal skill 中链接常驻执行提示词，不复制整份流程；消除未经授权前置复验的歧义。
- [x] 校验 UTF-8、Markdown 围栏、绝对文件链接、空白错误和 skill frontmatter。
- [x] 写闭环报告，核对抽查产品 hash 未变，明确本轮未运行游戏。

## 停止条件与边界

发现目标被其他会话并发改动时先重读再补丁，不覆盖。只编辑本计划、常驻提示词、两份旧试玩提示词的相关条款、temporal skill 的入口和本轮报告；不改代码、默认玩家设置、历史报告、成品或发布。此轮没有产品 candidate/champion 晋级。

交付：`G:/AIRTS/AI_RTS/agent/prompts/deepseek-background-video-playtest.md`；闭环报告：`G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-10-background-video-prompt-handoff.md`。
