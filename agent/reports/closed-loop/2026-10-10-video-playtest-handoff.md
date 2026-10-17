# 低帧率录像试玩：工具与纠正提示词交接

- 日期：2026-10-10，北京时间。
- 状态：录制工具及流程交接已验证；**真实 Godot 后台录像烟测已完成，完整玩家复验仍 needs-review**。
- 开发根：`G:/AIRTS/AI_RTS`；Git 根核验和编辑目标边界检查 rc=0。
- 初始工具交接未启动游戏；用户要求“先试试”后已完成独立真实游戏烟测。全程没有修改产品代码、场景、平衡表、打包成品或 GitHub release。

## 给 DeepSeek 的入口

读取并执行 [录像试玩纠正提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-10-deepseek-video-playtest-correction.md)。先通过输入/录像资格检查，再边录边玩，按时间段实际回看，交付带时间码的问题清单；本轮只审计，不修产品。

常驻规则：[airts-temporal-playtest](G:/AIRTS/AI_RTS/skills/airts-temporal-playtest/SKILL.md)，已由 [闭环验证工作法 §1.6](G:/AIRTS/AI_RTS/skills/闭环验证工作法.md) 引用。

## 为什么旧试玩不能作完整验收

已核对 [旧报告](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-10-single-player-playtest-issues-20261010-solo-playtest-01.md) 和动作记录。旧执行者如实标注了部分覆盖，但还有以下结论风险：

1. 点选、框选、右键、蓝图、编组等玩家路径 blocked；调试命令 Accepted 和少量位置样本只能证明 command-level，不能证明玩家可以正常操作。
2. 36 张截图和 24 份状态样本不足以观察持续位移、转向、碰撞、采矿交货、出生和特效时序。
3. “约两分钟判负并返回主菜单”有旧观察；“没有战斗却误判负”证据不足。玩家未下命令不代表 AI 没有攻击，需双方 HP、攻击/死亡、结果原因和连续录像。
4. 强杀后的新进程重开不能证明正常菜单退局/重开通过。
5. 窗口失焦、最小化与 DCS 鼠标失效的因果仍未确认；暂停时调试端不响应也不直接证明游戏死锁。
6. 指挥中心产品来源、被动收入及 UI 文案须对照当前规则和原尺寸画面，不能把设计差异、OCR 或控制台乱码直接升级为缺陷。

因此保留旧报告，不覆盖它，也不要求另一个模型按未经确认的根因立即修游戏。

## 真实 Godot 烟测结果

本轮用独立源码实例 `game-video-smoke-20261010-162148`，窗口放在屏外且未激活，用户可以继续使用前台应用；录制器没有调用 `SetForegroundWindow`、`SendInput` 或移动系统光标。实际画面通过 `PrintWindow` 捕获，`foreground=false`。

- [后台动作视频](G:/AIRTS/AI_RTS/agent/runs/game-video-smoke-20261010-162148/background-actions.mp4)：5 FPS、20 秒、100 帧、0 补帧、97 次相邻观测变化，已按 0.2 秒解码并打开 100 帧对应联系表。
- [后台空闲视频](G:/AIRTS/AI_RTS/agent/runs/game-video-smoke-20261010-162148/background-match.mp4)：5 FPS、20 秒、100 帧、0 补帧、96 次相邻观测变化。
- [动作时间线与状态摘要](G:/AIRTS/AI_RTS/agent/runs/game-video-smoke-20261010-162148/sequence-163145/summary.json)：MCP 身份 PID 与游戏 PID 一致；单位 `Unit_1` 被选中后位置从 `(28.918, 33.659)` 移到 `(32.785, 35.759)`，朝向也改变；录像中约 3.8 秒进入暂停菜单、约 5.8 秒恢复。该链路是引擎内事件，不证明真实鼠标玩家链路。
- [后台回看联系表](G:/AIRTS/AI_RTS/agent/runs/game-video-smoke-20261010-162148/review-actions/)：已实际打开 `sheet-001` 至 `sheet-009`；可见单位持续画面、移动后位置变化及暂停菜单。
- 性能对照（同一小局、同一后台窗口）：录制关闭 `fps` 中位数 `809`，录制中 `729.5`，关闭后 `798`；`process_ms` 中位数 `3.46 → 8.965 → 3.75`。这是录制器开销样本，不是大规模性能结论。

结论：**真实 Godot GPU 窗口在后台可以连续录制；用户不必让游戏前台，也不应被弹 CMD 或抢光标。** 但 `PrintWindow` 首次启动/切场景曾出现一次 3 秒抓取超时，必须预热后再录；真实玩家鼠标、框选、拖拽和编组仍不能在非干扰模式下认证。

已观察到部分捕获帧整体颜色变暗，原因未归因，不能把这段称为无画面瑕疵录像，也不能凭录像断言玩家画面同样闪烁。`Options.gd` 的居中逻辑覆盖初始窗口坐标，因此本轮仅验证了就绪后放屏外的稳定阶段；启动瞬间不激活尚未认证。曾试用的 `--no-focus` 未出现在引擎 help 中，已从工具移除，不能把未知参数当非激活保证。

本轮清理：[cleanup.json](G:/AIRTS/AI_RTS/agent/runs/game-video-smoke-20261010-162148/cleanup.json) 记录窗口 WM_CLOSE 正常关闭、游戏 rc=0、cleanup_ok=true；核验本轮 Godot/录制器均不存在，24781/24783/9090 无监听，实例登记无残留。watchdog 到期收尾，不等于暂停菜单主动退局通过。运行期间出现一次父租约写入 PermissionError，但最终实例正常关闭；不擅自归为游戏问题。

## 本轮改动

| 文件 | 作用 |
|---|---|
| [record_playtest.py](G:/AIRTS/AI_RTS/tools/dev/record_playtest.py) | 指定 PID/HWND 客户区录制 MP4，输出 UTC/monotonic 原点和逐帧实际捕获时间、重复帧、抓取耗时；按段解码原帧及联系表 |
| [video_smoke.py](G:/AIRTS/AI_RTS/tools/dev/video_smoke.py)、[video_smoke_sequence.py](G:/AIRTS/AI_RTS/tools/dev/video_smoke_sequence.py) | 本轮 localhost 独立实例及有界后台动作驱动；屏外窗口、仅引擎内事件、隐藏辅助进程、超时清理，不是全玩法自动化工具 |
| [test_record_playtest.py](G:/AIRTS/AI_RTS/tests/tools/test_record_playtest.py) | 离线边界/尺寸/回看测试及独立合成动画窗口烟测 |
| [temporal skill](G:/AIRTS/AI_RTS/skills/airts-temporal-playtest/SKILL.md) | 输入资格、录制、回看、证据分层和误归因约束 |
| [闭环工作法](G:/AIRTS/AI_RTS/skills/闭环验证工作法.md) | 追加动态玩法录像要求，保留无头逻辑回归和静态截图用途 |
| [纠正提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-10-deepseek-video-playtest-correction.md) | 重新执行有连续证据的玩家审计，不修产品；默认不弹 CMD、不抢焦点 |
| [原提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-10-deepseek-single-player-playtest.md) | 添加动态取证修订，保留原试玩范围 |
| [计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-10-single-player-playtest-plan.md) | 保留旧执行者状态，追加未执行的视频复验及工具交接进度 |

默认 5 FPS、宽度上限 1280、60-120 秒分段；窄口接触、转向、短攻击/特效用 10-15 FPS 的短片段。录像频率不是游戏帧率，不改 tick、time_scale、VSync 或正常画质。

录制器使用本机已有 `D:/software/anaconda3/python.exe` 的 OpenCV/numpy/Pillow，不需安装独立 ffmpeg。默认 PrintWindow；真实 GPU 画面无效时可改 screen 客户区采集，但必须保持目标窗口前台且无遮挡。输出只允许在 `agent/runs`，拒绝覆盖，不含声音或输入注入功能。

## 已做的验证

| 命令/核验 | rc / 结果 |
|---|---|
| `python tests/tools/test_record_playtest.py -v` | 0，3/3 通过；末次回看测试提取 15 帧、2 张联系表 |
| `python tests/tools/test_record_playtest.py --window-smoke` | 0，末次独立窗口录制 4 秒、5 FPS、20 编码帧，0 补帧，19 次相邻观测像素变化 |
| `python -m py_compile tools/dev/record_playtest.py tests/tools/test_record_playtest.py` | 0 |
| `python tools/dev/record_playtest.py --help` | 0，record/review 入口正常 |
| `python -X utf8 C:/Users/Administrator/.codex/skills/.system/skill-creator/scripts/quick_validate.py G:/AIRTS/AI_RTS/skills/airts-temporal-playtest` | 0，Skill is valid |
| 本轮 Python fixture/recorder 进程查询 | 无残留；只终止本轮拥有的 fixture |

末次录制证据：[MP4](G:/AIRTS/AI_RTS/agent/runs/recorder-smoke-20261010-155919-536782/synthetic-window.mp4)、[元数据](G:/AIRTS/AI_RTS/agent/runs/recorder-smoke-20261010-155919-536782/synthetic-window.json)、[逐帧时间](G:/AIRTS/AI_RTS/agent/runs/recorder-smoke-20261010-155919-536782/synthetic-window.frames.jsonl)。

已实际打开 [联系表 1](G:/AIRTS/AI_RTS/agent/runs/recorder-smoke-20261010-155919-536782/review/sheet-001.jpg) 和 [联系表 2](G:/AIRTS/AI_RTS/agent/runs/recorder-smoke-20261010-155919-536782/review/sheet-002.jpg)，覆盖 0-3.8 秒全部 20 帧。首帧为窗口启动白帧，后续深绿色背景上的粉色方块连续平移并回绕；只能证明合成窗口抓取/编码/解码/时间轴可用，不能证明 Godot GPU 捕获或玩法正常。先前一次成功烟测首帧没有该白帧，亦说明启动阶段须实际看图，不能仅信像素变化计数。

验证中曾有两次非产品失败：最初同进程 GUI fixture 导致测试父进程挂起，录制子进程已出视频但不算整项通过；核验自身 PID 7860 后终止，改为独立 fixture 进程，再次及末次烟测 rc=0。技能校验器默认 GBK 读 UTF-8 中文失败，使用 `-X utf8` 后 rc=0，未改全局校验器或把文档转为 GBK。

## 基线、并行风险与未验证项

工具候选经离线及独立窗口烟测后保留；没有产品 candidate/champion 晋级。基线是旧试玩缺少连续动态证据，新增能力是 5 FPS MP4、真实捕获时间戳和全帧回看；没有游戏性能或 BUG 修复前后数值。

共享工作区有大量既有未提交修改，未 reset/clean/stage/commit。抽查以下三个产品文件，本轮前后 SHA256 一致：

| 文件 | SHA256 |
|---|---|
| `project.godot` | `4EB544C494619DF60B906A406D947A25CA6B7A020CF52CBCD88EC07D7218E760` |
| `source/match/units/traits/Movement.gd` | `6C1004F21A8FAD18DF3C05145AB9C6BDD5E5C8A8116339C155EFEA8AED9375E6` |
| `source/net/DebugControlServer.gd` | `DB43B02ECE8FB3FAA6351C65055F35D69C458ACD8BE33648197062A0EE526780` |

尚未验证：实际玩家鼠标/框选/拖拽/编组、完整对局、旧问题的真实性及根因、声音；screen 前台捕获明确未在非干扰模式启用。未运行全量玩法回归，因为本轮仅修改取证工具和工作流、没有游戏修改，不能据此声称游戏通过。真实 Godot 后台捕获和短时录制开销已验证，但不替代 profiler 或大规模压力测试。

5 FPS 有 200 ms 采样间隔，会漏短瞬态；10-15 FPS 也不能替代 profiler、逐 tick 事件日志或无头状态断言。生成 MP4 或联系表不等于 AI 已看过，动态结论须标视频区间、已打开的帧和对应动作/状态。
