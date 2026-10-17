# AI_RTS 单人房试玩问题清单

- 状态：**审计完成（部分覆盖）**——不代表游戏已修好
- 执行日期：2026-10-10；run-id：`20261010-solo-playtest-01`
- 工程：`G:/AIRTS/AI_RTS`；Git commit：`9a2e6d4`（2026-10-08 20:50 +0800，"feat(release): 发布构建裁撤「地图生成」入口"）
- 引擎：`G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/`（Godot 4.7.1 stable Mono）
- C# 程序集：`OpenRTS.dll` SHA256 前 16 位 `41F23C3907E38A43`，mtime 2026-10-09 23:38:45（试玩开始前已存在的构建产物，本轮不重新构建）
- 工作区状态：git status 有大量未提交修改（其他会话遗留），本轮未做任何 reset/clean/checkout；试玩期间未发现源码被外部更新
- 实例与局：
  - 实例 1：PID 39928，14:03:25 启动。A 局（Plain & Simple，1 指挥官+3 空位，solo practice）14:07 开局，存活约 40 分钟，经菜单外手段（详见 ISSUE-001/收尾）于 14:47 结束。
  - 实例 2：PID 39048，14:47:23 启动。B 局（同图，1 指挥官+1 简单 AI）14:48 开局，**约 2 分钟后自动判负回主菜单**；B' 复现局 14:52 开局，**同样约 2 分钟自动判负**；C 局（1 指挥官+3 空位）14:55 开局并完成重开检查，14:58 收尾结束。
- 分辨率 1920x1080（窗口客户区 1765x993）；`run/max_fps=0`；vsync/physics tick：project.godot 未显式设置（默认）；HUD 实测 FPS 493~743
- 操作工具：DCS（`--debugport 24570`）`op=key` 键盘合成（有效）、`op=click/drag` 鼠标合成（失效，见 ISSUE-001）、command-level `move/build/produce/gather`（注明 command-level）、`op=screenshot/status/lobby/camera`；OS 级 SendInput/SendKeys 仅在窗口能保持前台时可用（受并行会话干扰）
- 实际试玩局数：4 局（A、B、B'、C）；墙钟约 55 分钟（超原预算 45 分钟）
- P0：1 项；P1：0 项；P2：3 项；P3/待确认设计：2 项；工具问题：3 项
- 覆盖率：见文末覆盖表

## 问题总表

| ID | 严重度 | 模块 | 玩家看到的现象 | 证据状态 | 复现次数/尝试次数 | 证据 | 建议处理顺序 |
|---|---|---|---|---|---|---|---|
| ISSUE-004 | **P0** | 对局生命周期 | 1 人+1 简单 AI 的本机单机局，开局约 2 分钟后无战斗自动判“失败”并强制返回主菜单，对局无法继续 | confirmed | 2/2 | Bp_status_1~5.json、B6 截图、godot.log 结算行 | **最优先** |
| ISSUE-005 | P2 | 生产 | 开局唯一建筑“指挥中心”拒绝一切生产（Worker/Drone 均 ProductNotAllowed），错误文案却提示“把工人订单发给指挥中心” | confirmed（command-level） | 2/2 | A 局 produce 返回 | 次优 |
| ISSUE-006 | P2 待确认设计 | 经济 | 无采矿交货时资金以约 +120/秒持续自涨，配表无对应规则；建造扣款被淹没无法核实 | confirmed（数值） | 2 局均出现 | A_status_* 采样序列 | 确认是否 demo 故意配置 |
| ISSUE-007 | P2 可达性 | 暂停菜单 | 暂停菜单 4 个按钮 focus_mode=0 不可键盘聚焦：纯键盘玩家无法“继续/设置/教学/退出战斗” | confirmed（代码+实测） | 1/1 | Menu.tscn:56-74、A28/A30 截图 | 次优 |
| ISSUE-002 | P3 待确认设计 | 单机大厅 | 槽位选“指挥官”会顶替原指挥官槽（原指挥官自动变简单 AI），释放后不恢复 | observed-once | 1/1 | A13/A17 截图 | 确认设计意图 |
| ISSUE-003 | P3 待确认设计 | HUD 文案 | 对局内“未选中单位”面板命令文案不可理解（“整到处成”“串成攻城者”“缓慢攻击”“团守”“圆卫”“消组装填”等） | observed-once | 1/1 | A20/A22 截图 | 核对文案来源 |
| 观察-001 | P3 观察 | 移动/寻路 | 日志高频出现“窄缝穿模：在缝外等待，通行证已被占用”“己方建筑脱困”“软穿行”，单位反复等待/降半径 | observed-once（日志） | 未定位玩家可见影响 | godot.log 尾部 | 定位 Unit_9 等被卡场景 |
| 观察-002 | P3 观察 | 单位成长 | 开局单位 hp_max 约 3 分钟内 6.0→7.5（+25%），无战斗无升级动作；C 局重开重置 6/6 | observed-once | 1/1 | A_status_gather*.json 对比 | 确认成长系统速率是否预期 |
| 观察-003 | P3 观察 | 建造 | 建筑放置会挤走占位单位（兵营落在矿车位置，displaced_unit_ids 非空） | observed-once | 1/1 | A 局 build 返回 | 确认 displacement 是否预期 UX |
| 观察-004 | P3 观察 | UI/迷雾 | 小地图对局前 30 分钟几乎全黑（仅视野中心一点+相机框），己方建筑已建多栋仍不显示 | observed-once | 1/1 | A20/A22/B3 截图 | 核对小地图渲染/信息来源 |

## 问题详情

## ISSUE-001：DCS 鼠标合成事件无效（工具问题，非游戏缺陷）
- 状态：tool-blocked（游戏侧鼠标功能未测，无法归因游戏）
- 局号：主菜单（未开局）；发现时间 14:05-14:12；前置：游戏窗口可见、DCS `--debugport 24570` 正常
- 复现步骤：启动游戏 → `op=screenshot` 正常 → 对主菜单按钮中心注入 `op=click`（合成 InputEventMouseButton + warp_mouse）→ 截图对比。
- 预期：按钮进入 hover/按下并触发跳转（依据：`DebugControlServer.gd` 注释“合成 InputEvent 走引擎输入管线，与玩家鼠标完全同路径”，2026-09-10 实测曾成功点击大厅“准备/立即开局”按钮）。
- 实际：4 次点击（主菜单“单机模式”(540,237)、“成长系统”(540,281)、换算坐标(587,306)、设置页槽位3下拉(495,270)）均无 hover 高亮、无跳转、无下拉展开；同窗口 `op=key`（Enter/Tab/方向键）全部立即生效。
- 已排除：截图坐标空间（viewport_size=window_size=1765x993，stretch disabled）、DPI（注册表 AppliedDPI=96，project.godot 无 hidpi 配置）。
- 玩家影响：无（真实鼠标未受影响——此为自动化工具问题）；对本轮影响：**框选、点选、右键移动、建造放置、集结点、技能指定等鼠标路径无法以玩家方式执行**。
- 重开复验：不适用（工具问题）。
- 截图：`agent/runs/20261010-solo-playtest-01/screenshots/A1_after_click_solo.png`、`A2_click_growth.png`、`A3_click_growth_scaled.png`、`A5_click_slot3.png`（均已打开查看，画面无任何反馈）。
- 可能原因：unknown（候选：非 console exe 下 warp_mouse/事件路由差异、窗口焦点状态、Godot 4.7.1 对 parse_input_event 鼠标位置的处理变化）。
- 建议下一步：用 console exe 复测一次以分离变量；对比 2026-09-10 成功时的窗口尺寸/启动参数；不作为游戏问题修复。

## ISSUE-002：单机大厅“指挥官”槽位顶替与不恢复
- 状态：observed-once（design-question）
- 局号：A 局大厅（未开局）；地图 Plain & Simple；前置：槽位1=指挥官(你)、槽位3=简单 AI
- 复现步骤：单机模式页 → 焦点到槽位3下拉（Tab）→ Enter 展开 → 上移选“指挥官” → Enter。
- 预期：未知（当前游戏规则未写明唯一指挥官约束的 UX），标注待确认设计。
- 实际：槽位3 变为“指挥官 3”，同时槽位1 从“指挥官（你）”自动变为“简单 AI”；随后把槽位3 改回“空位”，槽位1 仍保持“简单 AI”，需要手动再把槽位1 选回“指挥官”。
- 玩家影响：改槽位时玩家身份会被静默挪动，若不注意点开始会以“局里没有自己”的配置开局（本轮实际发生过一次中间态）。
- 复现次数/尝试次数：1/1（未重验）。
- 截图：`A13_slot3_empty.png`（顶替后中间态）、`A17_slot1_commander.png`（手动恢复后）。
- 可能原因：大厅存在“唯一指挥官”约束的互斥逻辑（推测，未读大厅代码验证）。
- 建议下一步：确认设计意图；若为约束，建议顶替时给出明确提示文案。

## ISSUE-003：对局内命令面板文案不可理解
- 状态：observed-once（design-question，需放大复核）
- 局号：A 局开局后；位置：右侧“未选中单位”面板快捷键列表。
- 实际：列表出现“整到处成 (C)”“串成攻城者 (A)”“缓慢攻击 (Z)”“团守 (G)”“圆卫 (V)”“消组装填 (B)”等非常规文案；同时 DCS `ra3_sidebar_ui` 返回的 caption 在控制台输出为乱码（GBK 显示问题，与截图无关）。
- 玩家影响：玩家无法从文案理解命令含义。
- 截图：`A20_a_match_start.png`（1080p 下文字可读）。
- 可能原因：占位文案/机翻/字符串表错误（unknown）。
- 建议下一步：对照 `assets/translations/match.csv` 核对键值；确认是否为当前语言缺失。

## ISSUE-004：1 人+1 简单 AI 单机局开局约 2 分钟自动判“失败”并强制返回主菜单（P0）
- 状态：confirmed（2/2 复现，均为“零玩家操作”局面）
- 局号：B 局（14:48 开局）与 B' 复现局（14:52 开局）；地图 Plain & Simple（4 人 · 208×208）；槽位：1=指挥官（你）、3=简单 AI，其余空位。
- 复现步骤：主菜单 → Enter 进“单机模式” → Tab 到槽位 3 = 简单 AI（默认配置）→ Tab 到“开始游戏” → Enter → 等待，不做任何操作。
- 预期：玩家基地完好、无战斗发生时，对局应持续进行（胜负判定依据应为基地毁灭等游戏规则；具体规则文件未指明，标注待确认）。
- 实际：开局后 90 秒时对局仍在（`match=true`、4 个单位、双方正常出生）；**t+120s 时 `match=false`**，游戏画面回到主菜单。两次复现时间一致（约 2 分钟）。期间无任何玩家命令（未 move/build/produce）、无鼠标键盘对局操作；status/lobby 只读查询不构成干扰。
- 玩家影响：**对 AI 的完整对局无法进行**（B 局流程在“探索→发展→交战”前就被强制结束），属于“对局无法继续”，定 P0。
- 复现次数/尝试次数：2/2。
- 截图/JSON/日志：`B5_prime_started.png`（B' 开局）、`B6_prime_after_3min.png`（回主菜单）、`samples/Bp_status_0~5.json`（含 t+90s match=true、t+120s match=false 序列）、`%APPDATA%\Godot\app_userdata\Open RTS\logs\godot.log`：`[对局] 已广播结果: 失败（本机房主，不回收进程）` + `[对局] 收到结算: 失败，3 秒后返回主菜单`。
- 可能原因：unknown（线索：`MatchEndHandler.gd` 在非 solo_practice 局按 `resolution.local_result` 判 Defeat；结果由 C# `MatchOutcomeRuntime` 发布；同图 solo practice 局（A/C）存活 30+ 分钟不判负，说明判定与“存在 AI 对手”相关；AI 经济日志正常（采矿交货、ResourceDepleted 重试警告），未见 AI 攻击行为）。
- 建议下一步：在 C# `IMatchOutcomeService` 判定处断点/加日志定位 2 分钟触发源（怀疑与 AI 侧结算或侧存活判定相关）；修复后回归场景=1 人+1 简单 AI 开局挂机 10 分钟不出结算。

## ISSUE-005：指挥中心拒绝一切生产且错误文案自相矛盾（P2）
- 状态：confirmed（command-level；玩家 UI 路径因鼠标阻塞未复测）
- 局号：A 局；前置：开局仅有 Unit_0（command_center）+ Unit_1（drone）。
- 复现步骤：`op=produce unit=Unit_0 scene=…/Worker.tscn` → 再试 `…/Drone.tscn`。
- 预期：错误文案写明“请把坦克订单发给车辆工厂，**把工人订单发给指挥中心**”，按此口径指挥中心应接受工人订单。
- 实际：Worker 与 Drone 均 `ProductNotAllowed` 拒绝（两次尝试均拒），返回的 reason 与拒绝行为矛盾；侧栏 tabs 显示 infantry/vehicles/aircraft 全部 disabled（仅 structures 可用），开局无任何途径产出单位（对照：兵营建成后可产步兵 `Accepted`，12 秒内出生在建筑出口）。
- 玩家影响：**开局生产链路断**——若设计是指挥中心只造建筑，则文案误导玩家（文案 bug）；若设计是可产，则开局无工人/单位来源（功能 bug）。二选一都需处理。
- 复现次数/尝试次数：2/2（Worker、Drone 各 1）。
- 截图/JSON：`samples/A_status_produce.json`（last_command ProductNotAllowed）；返回 JSON 全文见本轮 actions 记录。
- 可能原因：生产关系映射未给 command_center 注册产品，同时错误文案是旧口径残留（推测，未读 C# 生产校验）。
- 建议下一步：确认 command_center 的产品清单口径；统一文案与校验；回归=开局指挥中心产工人（若为设计）。

## ISSUE-006：无交货时资金约 +120/秒持续自涨（P2，待确认设计）
- 状态：confirmed（数值）；是否缺陷=design-question
- 局号：A 局（solo）；同样存在于 B/C 局。
- 实际：开局 10000 →（建矿场过程）10900 → 12100 → 13300 → 15700 → 17500 → 20500 → 22900 → 27700 → 28900 → 30000 → 33600 → 40200，折合长期速率约 +120/秒；期间矿车仅完成 1 次载货往返，交货金额无法与该收入分离。`demo.balance.v1.json` 未搜到 passive income/tick 收入规则。
- 玩家影响：资金近乎无限（3 分钟 +2 万），建造/生产的经济约束与“采矿交货”反馈被淹没；侧栏建筑价格（300~1200）失去意义。
- 复现次数/尝试次数：A/B/C 三局均出现（数值序列见 samples/A_status_*.json）。
- 可能原因：demo 配置的调试收入、或某建筑（矿场/指挥中心）自带产出、或规则系统被动效果（unknown）。
- 建议下一步：定位 +120/s 来源；若为 demo 故意配置，在平衡表注释并另出正式经济口径。

## ISSUE-007：暂停菜单按钮全部不可键盘聚焦，纯键盘玩家无法退出战斗（P2 可达性）
- 状态：confirmed（代码依据 + 实测）
- 局号：A 局对局中；按 Esc 打开“游戏暂停”菜单。
- 预期：菜单按钮可 Tab 聚焦、Enter 激活（对比：单机设置页全部控件可键盘操作，本轮全程键盘完成配置）。
- 实际：`Menu.tscn` 的继续游戏/设置/教学/退出战斗 4 个 Button 均 `focus_mode = 0`（FOCUS_NONE，56/62/68/74 行）；实测 Tab 无焦点移动。对局内按 Esc 后，若鼠标不可用（本轮工具阻塞）则唯一键盘出口是再按 Esc 关闭菜单，无法执行“退出战斗”。
- 玩家影响：键盘-only 或鼠标故障玩家会被困在暂停界面（只能 Alt+F4/任务管理器）；鼠标正常玩家不受影响（未实测真实鼠标点击，标注）。
- 复现次数/尝试次数：1/1。
- 截图：`A28_os_menu_restored.png`、`A30_os_after_exit_click.png`（菜单可见且点击/Tab 均无法推进）。
- 建议下一步：按钮改 `focus_mode = All` 或增加退出快捷键；回归=纯键盘从对局暂停菜单完成“退出战斗”。

## ISSUE-001（更新）：鼠标路径测试受阻的三层原因
- 原记录基础上补充本轮新证据：
  1. **游戏窗口被并行会话反复压后台/最小化**：本机另一 AI 会话（Codex IDE）持续抢占前台（`A24/A25/A33` 全屏截图均为 Codex 前台）；游戏窗口两次被检出到最小化状态（rect=-32000，`IsIconic=true`）。窗口最小化时 DCS 鼠标合成点击无从到达按钮——**鼠标合成失效的最可能解释**。
  2. **OS 级注入分化**：`mouse_event` 合成点击 2 次无效；`SendInput` 绝对坐标在窗口确实前置时有效（一次点击成功关闭暂停菜单——命中“继续游戏”或“退出战斗”未能区分，因 Codex 抢回前台导致后续点击落空）。
  3. 键盘合成（`op=key`）不受窗口前台状态影响，全程有效。
- 对游戏的归因不变：真实鼠标在正常前台窗口下大概率正常，本轮**无法验证**鼠标路径的任何游戏侧功能（框选/右键移动/建造 ghost/集结点）。

## 覆盖表与未测试项

| 模块/场景 | pass / failed / untested / blocked | 实际操作/证据 | 未测原因 |
|---|---|---|---|
| 开房/加载/生命周期 | pass（除自动判负外） | 4 次从主菜单键盘进局（A/B/B'/C），加载完成、HUD 与开局单位出现（B3/B5/C 局 status） | — |
| 对局自动结束 | **failed** | ISSUE-004，2/2 复现 | — |
| 主动退局（菜单） | blocked | Esc 菜单可开（A28），“退出战斗”键盘不可达（ISSUE-007）+ OS 点击被并行会话干扰 | 环境冲突；最终以 taskkill 结束实例 |
| 退局后再开/残留 | pass | C 局：资金重置 10000、单位全新 hp 6/6、无 AI、无旧局残留（C_status_1.json） | 换地图重开未测 |
| 镜头移动/缩放 | blocked | WASD/QE 映射存在但 op=key 同帧 press+release 对持续按键无效；op=camera 仅取证用 | 键盘合成机制限制 |
| 单选/框选/多选 | blocked | 鼠标合成失效（ISSUE-001）；无“全选”快捷键 | 鼠标路径无法执行 |
| 编组（Ctrl+数字） | blocked | op=key 无修饰键组合能力 | 工具限制 |
| 蓝图/建造（玩家 UI） | blocked | ghost/白区/旋转/取消退款未测 | 鼠标路径无法执行 |
| 建造逻辑（command-level） | pass（受限） | 矿场/兵营 Accepted 并完工；占位 Occupied 拒绝（(35,30)/(30,40)）；automatic 施工无需工人（A22 截图完工模型正常） | 注明 command-level |
| 寻路/移动（command-level） | pass（受限） | drone (28,28)→(31.4,33.1)≈目标(32,34)；worker 采矿往返位置序列正常 | 贴边/窄口/对向车队未系统测 |
| 经济/采矿 | pass（受限）+ ISSUE-006 | worker 自动随矿场出现；gather Accepted；载货 96→交货 carried 0→第二趟启动（位置序列） | 交货金额无法与被动收入分离；换矿点未测 |
| 生产/出生 | **failed（指挥中心）**+ pass（兵营） | ISSUE-005；兵营→步兵 12 秒出生于出口 (28,50) | 队列取消/退款/集结点未测 |
| 命令/战斗 | untested | B/B' 局 2 分钟内自动结束（ISSUE-004），未走到编组/接敌/伤害/死亡 | 被 P0 阻断 |
| 视野/迷雾 | limited | fog_visible=true、迷雾遮蔽正常；小地图信息异常少（观察-004） | 敌人显隐未测（无战斗） |
| 副官 | untested | 面板可见（接管/连通测试/3 个意图 tab），未实际接管 | 时间预算超支 |
| 特效/音效 | untested | 未采样音效（无音频采集能力，注明未验证）；特效未专门观察 | 时间与工具限制 |
| 性能/长时稳定 | limited | HUD FPS 493~743；A 局存活 40 分钟无崩溃；帧时间 p50/p95/p99 unavailable（无采集工具接入），>500ms 长帧未采集 | 时间预算超支 |

## 运行日志与收尾

- 启动命令（两次相同）：`Godot_v4.7.1-stable_mono_win64.exe --path G:\AIRTS\AI_RTS -- --debugport 24570`；PID 39928（14:03:25，A 局）、PID 39048（14:47:23，B/B'/C 局）。非 console 版无 stdout，日志用 `op` 返回 + `godot.log`。
- 结束：39928 于 14:47 `taskkill /T /F`（此前被 ISSUE-007+ISSUE-001 组合困在暂停菜单，属非正常退局，已在报告注明）；39048 于 14:58 `taskkill /T /F`（C 局收尾；solo practice 无自动结算、菜单退局同被环境阻塞）。
- cleanup_ok=**true**：两 PID 按进程树终止并核对不存在；TCP 24570 释放（netstat 无监听）；实例登记目录无本轮新增（未设 `AIRTS_INSTANCE_DIR`）；未按映像名/端口批量结束任何进程，未触碰其他会话实例。
- 工具问题（非游戏缺陷）：
  1. DCS `op=click/drag` 鼠标合成在窗口最小化/失焦场景无效（ISSUE-001）。
  2. DCS 在对局暂停期间整体冻结（autoload 未设 PROCESS_MODE_ALWAYS），暂停菜单期间无法截图/注入。
  3. OS 注入受并行 AI 会话（Codex）抢前台干扰；`mouse_event` 无效、`SendInput` 有限有效；`godot.log` 为多实例共享需过滤（混有 24569/24589/24592 等其他端口日志）。
  4. DCS status 响应带 32 位长度前缀且分块到达，一次性行解析会失败（本轮客户端已改为整包解析）。
- 游戏问题清单：ISSUE-004（P0）、ISSUE-005/006/007（P2）、ISSUE-002/003 与观察-001~004（P3）。
- 优先修复顺序：① ISSUE-004 自动判负（P0，阻断全部对 AI 对局）；② ISSUE-005 指挥中心生产矛盾；③ ISSUE-007 暂停菜单键盘可达性；④ ISSUE-006 经济口径确认；⑤ 文案（ISSUE-003）与小地图（观察-004）。
- 后续复验建议：修 ISSUE-004 后重跑“1 人+1 简单 AI 挂机 10 分钟”与完整 B 局玩法链（探索→建矿→采矿两趟→产兵→编组→接敌→撤退→退局）；修 ISSUE-007 后用纯键盘完成“暂停菜单退出战斗”；鼠标工具修复后补测框选/建造 ghost/集结点。
- 本轮证据根：`G:/AIRTS/AI_RTS/agent/runs/20261010-solo-playtest-01/`（screenshots 36 张、samples 24 份、dcs.py/raw_probe.py 驱动脚本、actions.md 时间线）。
