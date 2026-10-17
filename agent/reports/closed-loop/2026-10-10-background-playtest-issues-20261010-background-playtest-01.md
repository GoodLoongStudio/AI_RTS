# 后台录像试玩问题清单（20261010-background-playtest-01）

- 状态：**审计完成（部分覆盖）**——不代表游戏已修好或全测通过
- 提示词：`agent/prompts/deepseek-background-video-playtest.md`；计划：`agent/plans/2026-10-10-background-playtest-20261010-background-playtest-01.md`
- 执行日期：2026-10-10 18:00-18:41（墙钟 ~41 分钟）；run-id：`20261010-background-playtest-01`
- 工程：`G:/AIRTS/AI_RTS`；commit `9a2e6d4`；OpenRTS.dll SHA256 前 16 `41F23C3907E38A43`（mtime 2026-10-09 23:38:45，本轮开始前既有产物；是否对应当前源码：**unknown**，未重新构建）
- checker：plans/reports/record_playtest rc=0；`agent/runs` 为非源码证据目录（rc=2 预期）
- 非干扰模式：辅助进程 CREATE_NO_WINDOW；游戏窗口就绪后 SetWindowPos 屏外(-4000,-4000)+HWND_BOTTOM+NOACTIVATE（期间被外部最小化 2 次，仅还原 1 次并记录）；**启动瞬间是否短暂激活未认证**；全程无 OS 输入/warp/抢焦点（控制器内置拒绝 DCS click/drag 与 MCP warp_mouse）
- 实例：实例 1 pid 50768（DCS 25733/MCP 25736/控制器 25735，A 局，存活 17.8 分钟后无声退出 rc=1）；实例 2 pid 39120（DCS 25217/MCP 25220/控制器 25219，B 局，存活 11.0 分钟后无声退出 rc=1）。两实例均由 `match_instance.py` 登记核验（phase=controllable、parent_pid=驱动 pid）
- 录制：PrintWindow 客户区（实际 1765x993，`--resolution 1280x720` 被 Options.gd 覆盖）、5 FPS、宽 1280、无音轨（音效未测）；产出 6 个 clip + 联系表
- 输入通道：MCP `mcp_interaction_server.gd`（引擎内 click/key_press/mouse_move，`process_mode=ALWAYS` 暂停可用，get_instance_info 核验 pid/project_abs）＋ DCS 只读/键盘 op；command-level op 注明

## 问题总表

| ID | 严重度 | 模块 | 现象 | 证据等级 | 状态 | 复现/尝试 | 证据 |
|---|---|---|---|---|---|---|---|
| ISSUE-101 | **P1** | 战斗/平衡 | 对简单 AI：AI 开局即攻击玩家指挥中心，~80-120 秒内基地被磨毁判负，玩家几乎无反应时间 | log-only+状态序列 | confirmed（现象）/根因 unknown | 本轮 1/1 + 上一轮 2/2（旧报告口径修正：**不是"无战斗误判负"**，AI 一直在打） | godot.log [DAMAGE] 行、bwatch-*.json、clip-B02（partial） |
| ISSUE-102 | **P1** | 进程稳定 | 两个实例均在无退出日志、无 WER 记录下 rc=1 无声终止（17.8/11.0 分钟，均在对局中/后） | log-only | confirmed（现象）/根因 unknown | 2/2 实例 | godot.log 尾部无异常、cleanup.json game_rc=1、Windows 事件无 Godot 记录 |
| ISSUE-103 | P2 | 建造 UI | 侧栏建筑格点击后无放置模式反应（无 ghost/无状态变化），点地图不放置 | UI-synthetic | tool-blocked（归因受限） | 4/4 无反应 | M11/M12 截图、事件日志；根因候选：引擎内鼠标位置 (5141,4536) 与窗口客户区脱节（后台模式 get_mouse_position 失真），玩家真实鼠标路径未验证 |
| ISSUE-104 | P2 | 工具 | 后台模式下引擎内鼠标位置与画面坐标脱节（get_mouse_position=(5141,4536)），合成 InputEventMouseMotion 无法更新它；3D 拾取/放置类交互在非干扰模式不可验证 | UI-synthetic | tool-blocked | 1/1 | MCP input_state query 返回、mcp_interaction_server.gd 实现 |
| 观察-105 | P3 design-question | 强化系统 | "战区补给：三选一"每约 2 分钟一次、20 秒倒计时，超时自动采用推荐项；单机无暂停提示，读屏/切窗玩家易错过（本轮第一次即错过） | UI-synthetic | design-question | 1 次错过/2 次出现 | M7/M8/M10、clip-A02（partial 回看） |
| 观察-106 | P3 | 经济 | 两局资金增速差异巨大：A 局（无强化时被动≈6.7/s+交货 400/趟）vs 上一轮报告的 +120/s；交货额随"高效开采"强化与矿点而变 | command-level | design-question | 2 局对比 | sample-001~013.json、上一轮 A_status 序列 |
| 观察-107 | P3 | 移动/寻路 | 日志高频"窄缝穿模（在缝外等待，通行证已被占用）/软穿行/己方建筑脱困"，AI 单位反复等待与降半径 | log-only | observed-once | 未定位玩家可见影响 | godot.log 多处 |
| 观察-108 | P3 | 文案 | 槽位下拉实有 5 档（空位/指挥官/简单/中等/困难 AI），中等与困难 AI 本轮未测；上一轮"文案不可理解"问题本轮未复核（原尺寸截图未重拍） | UI-synthetic | untested | — | M4 截图 |

## 问题详情

### ISSUE-101（P1）：AI 开局 Rush 玩家基地，80-120 秒判负
- 严重度理由：玩家在对 AI 局中几乎没有发展窗口，核心玩法链（发展→出兵→交战）在正常节奏下无法完成；上一轮报告将该现象记为"疑似无战斗误判负"，本轮日志证据**修正归因**：AI 全程在攻击玩家指挥中心（`[DAMAGE] source=61879c88… target=Unit_0 owner=Player_0 amount=1 mode=Area`、`amount=0.5 mode=IntendedTargetOnly` 多条），判负时玩家基地持续掉血——**"AI 没攻击"不成立**。
- 局号/版本：实例 2 B 局；Plain & Simple（4 人·208×208）；槽位 1=指挥官（你）、3=简单 AI；commit 9a2e6d4。
- 步骤：菜单 → 单机模式 → 保持默认（1 人+简单 AI）→ 开始游戏 → 不做任何操作，只读采样。
- 预期：简单 AI 应给玩家发展时间（具体节奏规则文件未指明，标注待确认）；实际：t=70s 场上 6 单位（AI 已 4+），t≈80s match=false，随后进程退出。
- 复现次数/尝试：本轮 1/1（实例 1 的 A 局为纯单人局不可比）；上一轮 2/2（口径不同）。
- clip：clip-B02 @ 00:00-00:35（开局正常）；**判负瞬间未录到**（窗口被外部最小化致录制中断 + 进程死亡），伤害证据仅日志——证据等级 log-only。
- 根因假设：simple-clairvoyant-ai 开局 aggression/寻路过近（208×208 小图出生距离短）；反证：无（未做 AI 参数对照）。unknown。
- 建议定位：`source/match/players/simple-clairvoyant-ai/` 的开局策略与攻击决策时间表；复验轨迹=同配置开局挂机 5 分钟录 10-15 FPS 片段 + DAMAGE 日志时间线。

### ISSUE-102（P1）：实例无声终止（rc=1，两次）
- 现象：实例 1（A 局进行中，18:16）与实例 2（B 局 match=false 后 ~40 秒，18:29）先后无退出日志、无 WER 事件、无崩溃栈地结束（rc=1）。godot.log 尾部均为正常活动日志。
- 与"窗口被外部最小化"时间相关（实例 2 死前 35 秒窗口被最小化；实例 1 死前 7 分钟窗口曾被最小化又还原）——**相关性非因果**，unknown。
- 反证候选：父租约看门狗自退（日志无 launcher_gone/自退行，租约线程全程存活）；OOM/WER（无事件记录）；360 拦截（未查其日志）。
- 建议：以 console exe + 前台短局复测是否复现；查 360/驱动日志。本轮不归因为产品缺陷，但影响后续所有长局测试，列为 P1 待归因。

### ISSUE-103/104（P2，tool-blocked）：建造 UI 路径在后台模式不可验证
- 现象：MCP click 侧栏"矿场"格子 4 次均无放置模式反应；点地图不放置；点指挥中心不选中（对比：click 无人机选中 ✓、三选一按钮 ✓、右键移动 ✓、"开始游戏"按钮 ✓——均为 Control/event.position 路径）。
- 证据：M11/M12 截图（点击前后无变化）；`input_state query` 返回引擎内 mouse_position=(5141,4536)（真实光标相对屏外窗口的映射，超出客户区）；合成 InputEventMouseMotion 后仍不变（get_mouse_position 不吃合成事件）。
- 归因：**tool-blocked**——3D 拾取/放置若走 viewport.get_mouse_position() 则在屏外窗口必然脱节；玩家真实鼠标（前台）路径本轮无法验证，不判定为产品缺陷。修复测量需 warp_mouse（禁止）或用户授权的独占前台时段（未授权）。

### 观察-105：三选一强化系统
- 每 ~2 分钟一次（B 局前/A 局中各见一次），20 秒倒计时，超时取推荐项（金色"成长画像推荐/规则推荐"标注）；选项池含经济（高效开采 +25% 交货）、资源（工程备料/应急拨款 +5000）、军事（铁甲/老兵编制 HP+15/25%）。
- UI 点击选择路径可用（M10 证据）；倒计时错过 1 次（操作时序问题为主，无法完全排除点击时序边界，unknown）。
- design-question：倒计时期间单机局**未暂停**（提示词实现写"模拟已暂停"分支存在但单机实测未暂停——M7 时矿车仍在动？未专门验证，留待复核）；建议：单机暂停或倒计时延长。

## 覆盖表

| 模块/场景 | 结果 | 证据等级 | 说明 |
|---|---|---|---|
| 菜单导航/配置（键盘+MCP click） | pass | UI-synthetic | 主菜单→设置页→槽位/开始游戏；Tab 焦点链与上轮一致但初始焦点随进入方式变化（B 局误入槽 2 下拉，1 次操作失误重试成功） |
| 单击选择 | pass | UI-synthetic | click 无人机 → status selected=true（1/1）；click 指挥中心失败（见 ISSUE-103，tool-blocked 归因） |
| 右键移动 | pass | UI-synthetic | click(629,860,button=2) → drone (28,28)→(27,50.9) 朝资源点位移，selected 保持 |
| 框选/修饰键编组 | blocked | — | 引擎内无鼠标拖拽事件实现；key_press 无按住/组合（实现核验 mcp_interaction_server.gd） |
| 持续镜头按键 | blocked | — | key_press 单击 W 无镜头位移（按住时长仅 1 帧）；action 分支未测 |
| 蓝图/建造（玩家 UI） | blocked | UI-synthetic | ISSUE-103/104 |
| 建造逻辑 | pass | command-level | 矿场 (35,35) Accepted→建成；上一轮 Occupied 边界本轮未重测 |
| 经济/采矿 | pass | command-level+log | worker 自动出现；两趟以上循环（载货 400→交货 +400/趟 ×3）；REFINERY-CLAIM 在册 0/4 |
| 生产/出生 | untested | — | 未造兵营（时间+工具预算），兵营→步兵链沿用上一轮 command-level 结论不重复计 |
| 战斗/伤害 | partial | log-only | AI 攻击玩家基地（DAMAGE 日志）；玩家主动交战未测（ISSUE-101 时间窗不允许） |
| 对局结束/退局 | failed→进程死亡 | log-only | B 局 ~80s 判负（match false）；菜单退局未验证（进程死）；正常退局 pass 与否：**未测** |
| 副官 | untested | — | 未接管（时间预算） |
| 音效 | not-applicable | — | --audio-driver Dummy + 录像无音轨，本轮设计上不可测 |
| 录制质量 | pass（1/6 partial） | — | qual/A01/A02/B01 完整；A03 rc=1、B02 35s 中断（窗口最小化）；0-6 补帧；changing 帧计数正常 |
| 非干扰合规 | pass | — | 全程 foreground=false 的连续片段画面/状态变化（qual-01 切页、B02 迷雾扩张）；控制器拒绝 click/drag/warp/OS 输入；无 SetForegroundWindow/置顶（除 1 次 SW_SHOWNOACTIVATE 还原，见 review.md） |

## 工具资格记录

- 录制器：短测 25s → 125 帧/0 补帧/完整 ✓；`--resolution` 被 Options.gd 覆盖为 1765x993（--position 同样被覆盖，需就绪后 SetWindowPos 屏外——与烟测一致）。
- MCP click：主菜单/设置页按钮、三选一按钮、"开始游戏"全部真实生效（UI-synthetic）。
- MCP key_press：Tab/Enter/方向键真实生效；无按住与修饰键组合（blocked 根因）。
- MCP mouse_move：合成 motion 不更新引擎内鼠标位置（ISSUE-104）。
- MCP 暂停可用性：本轮未实测暂停菜单（Esc 菜单未开）；process_mode=ALWAYS 为实现证据，非实测 pass。

## 运行日志与收尾

- 启动：实例 1 18:00:47（drive.py pid 5444）、实例 2 18:20:30（pid 51160）；均非 console 引擎 + `--path G:/AIRTS/AI_RTS` + `--debugport` 动态 + GODOT_BRIDGE_PORT/TOKEN 注入；登记 parent_pid=驱动 pid 核验 ✓。
- 结束：两实例均自行无声终止（rc=1，ISSUE-102）；drive.py finally 均执行（终止录制器、WM_CLOSE 尝试、按 pid 树 stop）。
- cleanup_ok=**true**：10 个本轮 PID（2 游戏 + 2 驱动 + 6 录制器）tasklist 全部不存在；7 个相关端口无监听；instances 登记目录无实例残留（仅 parents 租约目录，租约已随驱动退出删除）；未按映像名/端口批量杀进程，未触碰用户/其他会话进程。
- 用户干扰事件：窗口被外部最小化 ×2（18:09、18:28），1 次还原记录在案；用户切窗口不算游戏故障。
- 证据根：`G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/`（drive.py/client.py/post_json.py/sample_states.py/watch_match.py、events/events.jsonl、video×6、review/、states/、screenshots/、review.md、identity.json、cleanup.json）。
- 优先复验建议：① ISSUE-101 AI 开局 Rush（AI 参数/地图距离，10-15 FPS 录像+DAMAGE 时间线）；② ISSUE-102 进程无声终止（console exe + 最小化状态对照）；③ 前台授权时段补测建造 UI/框选/编组；④ 中等/困难 AI 与三选一暂停行为。
- 本轮未修任何产品代码/场景/配表；未改打包版；未宣称游戏通过。
