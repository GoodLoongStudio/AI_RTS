# DeepSeek 后台录像试玩：常驻提示词交付

- 日期：2026-10-10，北京时间。
- 状态：文档重写与静态校验完成；DeepSeek 新一轮实际试玩尚未执行。
- 工程：`G:/AIRTS/AI_RTS`，Git 根核验及六个实际编辑目标边界检查 rc=0。
- 范围：仅测试指导文档。未启动新游戏、未修改产品代码/录制工具/玩家设置、未打包或发布。

## 交接入口

[常驻执行提示词](G:/AIRTS/AI_RTS/agent/prompts/deepseek-background-video-playtest.md) 可独立转发，无需旧对话或旧报告才可执行。默认后台单人房玩家审计，不授予修游戏权限。

可直接发给 DeepSeek：

```text
请读取 G:/AIRTS/AI_RTS/agent/prompts/deepseek-background-video-playtest.md 并执行。
从正常菜单开本机单人房，在不弹辅助 CMD、不抢焦点、不移动我的光标的条件下，
边操作边录低帧率连续视频，实际分段回看，并关联动作时间线与状态数据。
将本轮发现的问题、复现步骤、视频时间码和未测试项写入新的 Markdown 报告。
本次只试玩审计，不修代码、不改评审包；测不通的项目如实标 blocked，不冒充通过。
```

## 基线与改动

基线：旧单人试玩提示词仍允许 MCP 失败后自动使用原生窗口输入；纠正提示词称仅合成窗口测试通过，与已经完成的真实 Godot 后台烟测不符。skill 另有一句前置复验建议未写独占授权条件。

新口径：后台非干扰是门禁；MCP 引擎内事件、原生输入、command-level、headless、log-only 证据分别标明；默认 5 FPS/1280 宽/60-120 秒，关键短事件 10-15 FPS；异步边玩边录，并实际查看关键采集帧。每项问题关联视频时间码、动作、状态、复现次数，输入/启动阻塞不升级为产品缺陷。

| 本轮文件 | 改动 |
|---|---|
| [常驻提示词](G:/AIRTS/AI_RTS/agent/prompts/deepseek-background-video-playtest.md) | 新建独立执行入口，包含工具资格、玩家轨迹、覆盖表、证据/误归因边界、超时与所有权清理 |
| [旧单人提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-10-deepseek-single-player-playtest.md) | 指向新入口，删除自动原生输入 fallback，统一录像宽度口径 |
| [旧纠正提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-10-deepseek-video-playtest-correction.md) | 指向常驻入口，更新真实后台录制已短测但完整玩法未认证的事实 |
| [temporal skill](G:/AIRTS/AI_RTS/skills/airts-temporal-playtest/SKILL.md) | 链接可复用提示词，前置复验须有用户明确独占授权 |
| [本轮计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-10-background-video-prompt-plan.md) | 文档任务 checklist 和边界 |
| 本报告 | 交付、验证与残余限制 |

没有产品性能/玩法改前改后数值，没有产品 candidate/champion 晋级，连续未提升轮数不适用。未覆盖原试玩计划的历史勾选或旧报告。

## 验证

| 命令/检查 | 结果 |
|---|---|
| `git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel` | rc=0，根为主工程 |
| `python G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target <六个实际绝对目标>` | 六项均 rc=0、allow |
| PowerShell 严格 UTF-8 解码、Markdown 围栏成对、绝对文件链接存在、行末空白 | rc=0；包括 Git 未追踪/忽略的新文档 |
| `python -X utf8 C:/Users/Administrator/.codex/skills/.system/skill-creator/scripts/quick_validate.py G:/AIRTS/AI_RTS/skills/airts-temporal-playtest` | rc=0，Skill is valid |
| `git -C G:/AIRTS/AI_RTS diff --check -- <本轮六个路径>` | rc=0；仅 Git 可见差异，因此另做上述全文件检查 |
| 读取 MCP/DCS 和录制器实现，与提示词参数/限制对照 | MCP click 隔帧；DCS click 有 warp；录制器 record/review 参数及元数据口径一致 |
| 产品文件 SHA256 前后抽查 | 下列三文件一致 |

| 文件 | 本轮前后 SHA256 |
|---|---|
| `project.godot` | `4EB544C494619DF60B906A406D947A25CA6B7A020CF52CBCD88EC07D7218E760` |
| `source/match/units/traits/Movement.gd` | `6C1004F21A8FAD18DF3C05145AB9C6BDD5E5C8A8116339C155EFEA8AED9375E6` |
| `source/net/DebugControlServer.gd` | `DB43B02ECE8FB3FAA6351C65055F35D69C458ACD8BE33648197062A0EE526780` |

## 未验证与共享风险

本轮是文档任务，按 RSI 文档例外未重跑真实 Match、截图/录像、编译或玩法套件。既有 [后台烟测证据](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-10-video-playtest-handoff.md) 仅说明当时独立窗口 PrintWindow 5 FPS/20 秒/100 帧可用；不是本轮新测试，也不是完整玩家验收。截图/视频路径在该报告中保留。

启动瞬间不激活尚未认证；Options 可能覆盖窗口位置；框选/持续按键/编组/蓝图等须逐项资格测试；部分捕获帧颜色异常未归因；默认视频无声音。新提示词明确不把这些限制掩盖成 pass。后续执行者必须给出本轮覆盖及缺口，不能保证所有 BUG 已被找全。

共享树检查时有 956 个既有状态条目；未 reset/clean/stage/commit，未回滚其他会话。仅上述文档精确补丁，产品 hash 抽查不是整个共享工作树冻结证明。本轮没有新增长驻进程需要清理。
