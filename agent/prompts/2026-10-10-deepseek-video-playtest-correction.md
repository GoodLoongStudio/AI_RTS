# DeepSeek 纠正提示词：用低帧率连续录像重新试玩

此文件保留对旧报告的纠正背景；以后执行使用 [常驻后台录像试玩提示词](G:/AIRTS/AI_RTS/agent/prompts/deepseek-background-video-playtest.md)，不依赖这份旧报告才开始测试。启动/输入/捕获约束以常驻入口和 temporal skill 为准。

你上一轮报告是 `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-10-single-player-playtest-issues-20261010-solo-playtest-01.md`。它保留了有价值的现象，但点选/框选/右键/蓝图等关键玩家输入 blocked，战斗/副官/特效未测，36 张散截图和稀疏状态样本无法证明动态玩法正常。本轮必须补动态证据，不能重复同样的挂机和截图方式。

先读 `AGENTS.md`、workspace boundaries、闭环工作法、RSI、`agent/manifest.json`、`agent/mcp/README.md`、原试玩提示词和 **`G:/AIRTS/AI_RTS/skills/airts-temporal-playtest/SKILL.md`**。不修产品、不改测试判据、不修改评审包/发布，不覆盖上一轮报告。

**2026-10-10 用户追加约束：测试不能弹辅助 CMD 窗口、抢焦点或移动用户光标，用户会同时聊天和使用电脑。默认后台非干扰模式，禁止 OS 输入注入以及 DCS 内 warp_mouse 路径。仅在用户明确同意独占时段后才能做前台 OS 输入或 screen 录制；不能自行 fallback。后台 UI 事件不支持的项标 blocked，命令级观测不升级为 UI pass。**

## 先证明自己能操作，再试玩

用本轮独立实例核对 PID/HWND、工程/hash、画面与坐标；不要接管用户窗口。录一段 15-30 秒资格片段，分别验证：菜单点击、进入房间、点选、框选、右键移动、按住镜头移动键、修饰键编组、暂停/恢复。每项必须有操作前后变化与时间码。按下和释放隔开、记录 modifier，不能把同帧 press/release 当作持续按键。

默认只用不改变系统光标/焦点的引擎内输入；不满足非干扰条件的接口直接停用。鼠标 API 返回 Accepted 不等于游戏接收，失焦不是未经复验即可确认的根因。重试最多两次；资格不通过就写工具阻塞报告，保留证据，不耗 40 分钟挂机假装玩了游戏。无头和 command-level 只能标补充，不能将 UI 项改为 pass。

## 独立录制、边录边玩

本机可用 `D:/software/anaconda3/python.exe`，已有 OpenCV/numpy/Pillow；没有验证到独立 ffmpeg 命令，不要虚构已安装。现成工具：`G:/AIRTS/AI_RTS/tools/dev/record_playtest.py`。

```powershell
python G:/AIRTS/AI_RTS/tools/dev/record_playtest.py record --pid <本轮游戏PID> --fps 5 --seconds 120 --output G:/AIRTS/AI_RTS/agent/runs/<新run-id>/video/clip-01.mp4
python G:/AIRTS/AI_RTS/tools/dev/record_playtest.py review --video G:/AIRTS/AI_RTS/agent/runs/<新run-id>/video/clip-01.mp4 --start 0 --end 30 --step 0.2 --out G:/AIRTS/AI_RTS/agent/runs/<新run-id>/review/clip-01-000-030
```

驱动用隐藏子进程异步运行 record，同一时间继续操作游戏。不要等 120 秒录完才开始操作。默认仅录目标窗口客户区、无声音；2026-10-10 已完成本机真实 Godot 4.7.1 后台 5 FPS/20 秒烟测，详见 `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-10-video-playtest-handoff.md`。这不保证新环境、所有输入或启动不激活；`PrintWindow` 仍可能黑屏/白屏/冻结或抓取超时，先短测验证。**非干扰模式下 PrintWindow 失败不能擅自换 `--method screen`**，因为 screen 要求游戏前台且会妨碍用户；改用后台兼容捕获、延后预热或标记 blocked。只有用户明确同意独占前台时段，才可使用 screen，并在结束后恢复用户环境。不要改变游戏 FPS/tick、使用 Godot 离线电影模式或用每秒 5 次同步 DCS 截图代替录制。

正常玩法 5 FPS/约 1280 宽、每段 60-120 秒；转向/接触/战斗/短特效另录 10-15 FPS 的 20-40 秒局部片段。录制前后保留完整动作过程。全局动作表记录 monotonic/UTC、局号、输入坐标/键与按住时长、选中对象、目标、工具回执及实际反应；状态采样默认只读 1-2 Hz，事件边界按需要加强但不无界排队。

连续记录 MP4、同名 JSON 和 frames JSONL，检查总帧/真实捕获/重复帧/时长。`DUPLICATE / UNOBSERVED` 表示录制迟到补帧，不代表游戏停住；5 FPS 是录像频率，不能据它算游戏 FPS/p95 或命令延迟。性能另外测录制关闭条件，音效未录则标未验证。

## 必须按段回看，不是录完就算

视频接口能读取时按连续时间范围看；否则运行 review 生成带时间码联系表和原始帧，**实际逐张打开查看**，每个关键动作/疑似停走区间用 0.2 秒步长看 5 FPS 全部采集帧。长静态段可粗览后密看异常段；首尾两张图不能证明整个过程，联系表中字太小须打开原帧。

写 `agent/runs/<新run-id>/review.md`：每个 clip 已看秒数区间、打开哪些图、命令时间、位移/朝向/载货/HP/队列的变化、错误和不能确认的部分。生成 review 文件或 mp4 的成功输出不代表模型已经看过。

先覆盖：主菜单正常单人开房 → 建矿场 → 矿车至少两趟 → 产兵/出口 → 点选/框选/右键/编组 → 绕建筑/窄口/转向 → 副官探索 → 正常菜单退局重开。再开单机对简单 AI 补交战，若自动判负则连续录下触发前后，记录双方单位/基地 HP、攻击与死亡、胜败事件原因，不能仅因自己没发攻击命令就称“没有战斗”。

## 纠正上轮结论的口径

- 保留“约两分钟返回主菜单/显示失败”的旧观察，重新核验当前版本；是否误判、被攻击、哪条胜敗规则触发，缺证据就 unknown。
- Command-level 生产拒绝不直接证明“所有玩家生产途径断了”；先核对当前建造/矿车来源和正常侧栏操作。
- 资金上涨需区分采矿、被动收入/成长/版本规则，不能只因 balance 一处没搜到就定为 BUG。
- 文案先打开原尺寸图并对照实际 UI 字符串，不把 OCR/终端乱码当游戏文字错误。
- taskkill 后再开新进程只能证明异常终止后重启，不能认证“菜单主动退局通过”；分开记录正常退出、异常强杀和进程清理。

## 最终 .md 交付

新文件：`G:/AIRTS/AI_RTS/agent/reports/closed-loop/<日期>-video-playtest-issues-<新run-id>.md`。

每项问题沿用旧问题 ID 或注明关联，附 **`clip-XX.mp4 @ mm:ss-mm:ss`**、原帧/数据/日志绝对路径、玩家复现动作、预期/实际、复现次数/尝试次数、证据等级（UI-player / command-level / headless / log-only）、可能原因与未确认项。

覆盖表逐模块写 pass/failed/blocked/untested；输入或动态过程没完成不能写 pass。列已回看视频的总区间、采集/遮挡/缺帧、真实玩法链完成程度、正常退出与 cleanup。本轮只审计，不修代码、不宣布穷尽 BUG；如果工具资格仍失败，交付部分/blocked，不把时间花在重复截图挂机。
