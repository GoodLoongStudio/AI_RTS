# DeepSeek 后台试玩报告：独立事实核验

日期：2026-10-10，北京时间。核验对象：[原问题报告](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-10-background-playtest-issues-20261010-background-playtest-01.md)、[原回看记录](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/review.md) 和 `G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/` 的原始产物。

**结论：确实运行过游戏并产生了真实证据，不能说整份是假报告；但多项事实、计时、工具能力和 pass 判定有错误，只能接收为部分测试记录，不能当作完整玩家试玩验收或据此直接修改 AI 平衡。** 本轮只审计历史证据，不修产品、不启动新对局、不覆盖原报告。

## 必须更正的结论（按影响排序）

### 1. ISSUE-101 的“开局 80-120 秒判负”和 P1 平衡判断证据不足

AI 对玩家基地造成伤害属实：[日志](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/logs/godot.log) 有目标 `Unit_0 owner=Player_0` 的 DAMAGE；采样中基地 HP 从 80 降至 70.5、39、4。但采样脚本 [watch_match.py](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/watch_match.py:50) 的 `t_s` 是脚本启动后的时间，不是对局开始时间。

| 事件 | 实际记录时间 | 距开始点击 |
|---|---|---|
| 单机开始按钮 click(881,727) | 18:27:58.237 | 0 秒 |
| 基地 HP=4，outcome=InProgress | 18:30:45.854 | 167.616 秒 |
| 首个 match=false | 18:30:55.863 | 177.626 秒；文件里 t_s=80.1 |

开始点击来自 [events.jsonl](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/events/events.jsonl)；后两项为 [bwatch-006](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/states/bwatch-006.json)、[bwatch-007](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/states/bwatch-007.json)。加载约数秒，合理表述为“开始按钮后约 168-178 秒间对局消失”，不能写开局 80 秒。`match=false` 只证实不在 Match，不包含最终 Defeat 原因/胜败事件；本轮没录到基地毁灭/判负画面，判负链仍缺最后一段证据。

更关键的是，B 局记录明确“不做任何操作，只读采样”。挂机约三分钟被 AI 打败不能证明主动发展的玩家没有反应时间；尚无正常建造/出兵/防守对照，也无简单 AI 应等待多久的产品规则。**保留“AI 伤害基地并出现退局”的观察；撤回已确认 P1 平衡缺陷、开局即攻击和 80-120 秒的强结论，待复验。** 上轮 2/2 不能混成当前版本的 3/3 复现。

### 2. “没有拖拽/持续按键实现”与已有源码矛盾

MCP 文件 mtime 为 2026-09-30，早于本轮。已有入口和实现：

- [key_hold](G:/AIRTS/AI_RTS/autoload/mcp_interaction_server.gd:1296)：按下不自动释放，支持 key/action。
- [key_release](G:/AIRTS/AI_RTS/autoload/mcp_interaction_server.gd:1324)：释放对应输入。
- [mouse_drag](G:/AIRTS/AI_RTS/autoload/mcp_interaction_server.gd:1387)：分帧发送按下、motion（button_mask）和释放，函数内没有 warp_mouse/OS 输入。
- `key_press` 的 action 分支支持 Input.action_press/action_release，不止一帧单击。

events 中只有一次 W 的 key_press，没有 key_hold/key_release/mouse_drag/action 资格尝试。因此框选、持续镜头应写 **“已有候选接口，未资格测试/未验证”**，不能写“引擎内无实现”。组合键/modifier 对玩家编组能否生效仍须逐项实测，源码有接口不等于玩法通过；本轮不补测运行时。

### 3. ISSUE-103 的“侧栏完全无放置模式反应”与截图矛盾

原 [M11](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/screenshots/M11_ghost.png)、[M12](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/screenshots/M12_ghost2.png)，以及更早的 [M10](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/screenshots/M10_aug2.png) 都有清楚的白色可建造区域；M8 没有该区域，画面确实改变了。源码 [StructurePlacementHandler.gd](G:/AIRTS/AI_RTS/source/match/players/human/StructurePlacementHandler.gd:250) 在添加蓝图后激活 BuildPlacement 并显示该范围。

这支持至少某次 UI 操作已进入放置状态，不能标“4/4 完全无响应”。更合理的是“建造范围出现，但 ghost 没在可见地图正常跟随，合成点击未完成放置”。[input_state](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/events/events.jsonl) 的 mouse_position=(5141,4536) 属实，[蓝图定位代码](G:/AIRTS/AI_RTS/source/match/players/human/StructurePlacementHandler.gd:288) 又使用 viewport.get_mouse_position，后台屏外坐标不匹配是有依据的工具阻塞方向。

但“所有 3D 拾取不可验证”“只能 warp 或前台”过度外推：本轮自己已证明无人机选择和右键移动成功。这里只能确认当前建造输入链受阻，未证明真实玩家建造坏了，也未排除可改进的后台事件/虚拟指针方案。

### 4. 录像质量数量错误，关键动作未实际回看

本轮独立用 OpenCV 将每个 MP4 解码至 EOF，结果：

| 文件 | 可解码帧 / 秒 | 元数据状态 | 补帧 |
|---|---|---|---|
| qual-01 | 125 / 25 | complete | 0 |
| clip-A01 | 450 / 90 | complete | 9，原 review 错写 0 |
| clip-A02 | 299 / 59.8 | partial，目标 hidden/minimized | 0；不是“90 秒完整” |
| clip-A03 | 0 / 无有效时长 | 44 字节、无 moov atom、无同名 metadata | 无法判定；不能算有效 clip |
| clip-B01 | 600 / 120 | complete；此时在菜单配置，未开局 | 0 |
| clip-B02 | 175 / 35 | partial，目标 hidden/minimized | 6 |

准确口径是 **6 个 MP4 文件名，5 个可解码片段，3 个 complete、2 个 partial、1 个无效；总计 1649 帧/329.8 秒，不是“1/6 partial、0-6 补帧”**。

原 review 明确列出的已看内容只有四张联系表，每张 12 帧，共 48 帧，按 5 FPS 约 9.6 秒，仅占可解码帧的 2.9%。它承认 A01/B01 未看，A03 无效；采矿段、玩家移动段、战斗判负段没按提示词回看。生成其他联系表不自动算看过；不能凭文件存在确定它在别处是否打开过，但现有回看记录明显不足以支持关键轨迹验收。

### 5. “全程 foreground=false、非干扰 pass”过强

逐帧日志实际有 foreground=true：A01 5 帧（43.8-44.6 秒）、A02 4 帧（59.0-59.6 秒）、B02 20 帧（29.2-34.8 秒）。这推翻“全程后台”的描述，但**不能证明是 AI 抢焦点**；用户点击任务栏等也是可能来源。

hidden/minimized 错误不能区分被隐藏还是最小化，更不能证明“外部/用户”是执行者。报告称首次 18:09:50 已还原，事件却在 18:10:31 仍失败、18:10:51 才恢复可捕获；单次 ShowWindow 没有对应原始事件记录可核验。第二次失效以 B02 元数据为准是约 18:29:10，不是 18:28:30。

驱动源码确实使用 CREATE_NO_WINDOW/NOACTIVATE，MCP click 不 warp，不能据此证明系统全程没有其他影响。启动瞬间不激活未认证已写清；有后台刷新片段属实，应接受为“稳定阶段后台捕获可用”，全面非干扰验收需保留 unknown。

### 6. ISSUE-102：第二实例 rc=1 属实，第一实例完整退出证据被覆盖

现存 [cleanup.json](G:/AIRTS/AI_RTS/agent/runs/20261010-background-playtest-01/cleanup.json) 只属于第二实例，mtime=18:31:31，game_rc=1，window_close=false，normal_menu_exit_verified=false。此前本会话在 18:30 左右独立观察到 PID39120 仍运行，18:31 后消失，支持第二实例退出事实；原详情写“18:29 退出”错误。

驱动两次复用同一 run-id、identity.json、cleanup.json、godot.log 和实例日志名；[match_instance.py](G:/AIRTS/AI_RTS/tools/dev/match_instance.py:522) 对 out/err 使用 w，原实例日志/清理/身份已被第二实例替换。第一实例有早期 MCP 身份及状态/录像，但没有保留它的最终 cleanup 或退出码原件，因此不能以现存证据完全认证“两次均自然无声退出 rc=1”。A 状态在 18:18:16 仍可读，与详情“A 在18:16终止”也冲突。

18:00-18:42 的 Application 1000/1001/1026 查询无相关记录属实；没有 WER 不等于没有崩溃/外部终止/工具看门狗。驱动 finally 含强制 stop，必须保留 stop 前 poll/原因时间线才可定“自行退出”；目前产品退出根因 unknown，不能归因 360/最小化/OOM。

### 7. 状态采样混轮，完整性不合格

bwatch 文件编号不是单条连续时间线：bwatch-002 时间18:29:55，003 却18:22:49，004 又18:30:25；011-026 为18:24-18:26、早于正式 B 开局。脚本每次 index=0 并写同名 bwatch/sample，因此重复运行会覆盖前缀却保留旧尾巴。独立计时必须按 UTC/monotonic 和 Match ID 分组，不能按文件序号拼接或把菜单阶段 match=false 当正式 B 结束。

此问题还影响 log-only 根因分析和第一局记录。后续每个实例/每次采样应有独立目录，产物不覆盖，记录 PID/Match ID、采样开始与实际 Match 就绪时间。

## 有证据支持的事实

| 原报告条目 | 独立核验结果 |
|---|---|
| 实际运行工程/两个 PID | MCP 身份分别 PID50768、39120，工程 `G:/AIRTS/AI_RTS`，Godot4.7.1，成立 |
| commit/DLL 信息 | 当前 HEAD=9a2e6d4，Debug DLL hash/mtime 与原报告相符；是否对应所有当前 C# 源码仍 unknown |
| 菜单→单机页面 | 原 qual 联系表确实从菜单切设置页，成立 |
| 无人机点选/右键移动 | 独立看 A01 34-38.8 秒有选中标记出现，56-63.8 秒连续位移；事件/状态从 (28,28) 到 (26.972,50.910)，成立，但只限该单位路径 |
| 三选一存在/超时默认 | M7剩8秒、M8老兵编制、A02约10.8秒遮罩消失，成立；第一次选择点击在18:08:33，实际遮罩约18:08:10.5已消失，不能判点击故障 |
| ISSUE-104 鼠标坐标脱节 | input_state 返回(5141,4536)，成立；前后成对验证缺失，不外推全部输入 |
| command-level 矿场建成及交货 | build Accepted，采样出现矿场/worker；sample003→004、006→007、009→010 均载货400→0、资金+400，至少三次交货逻辑成立，未认证玩家 UI 或采矿动态画面 |
| AI 攻击基地/掉血 | DAMAGE 和本轮 HP 80→70.5→39→4 支持，成立；胜败最后一步未记录 |
| 移动降半径/窄缝等待日志 | 多处原日志支持，成立；玩家可见空气墙/卡顿影响未测 |
| 生产/副官/框选/正常退局等未测 | 原报告多数已坦承；不能标完整试玩。框选的未测理由需改正 |
| 当前残留清理 | 独立查询10个相关 PID 不存在、7个列明端口无TCP监听/UDP端点、instances无文件；当前结果成立，不证明原时刻所有动作或正常退局通过 |

观察-106 被动收入≈6.7/s 和与上轮+120/s比较缺可比条件；本轮动作状态资金先固定10000、强化后15000，后段是离散交货+400。不能从净余额变化推被动收入率。音效应标 untested（Dummy/无音轨），不是证明产品音效不适用。ISSUE-107/108、强化暂停节奏等保留观察/设计待确认，不当已确认 BUG。

## 本轮独立查看与命令

未重新开游戏，独立解码历史录像/读JSON/源码/日志，未触碰产品或原证据。

- 原 review 的四张联系表均实际打开，菜单切换/单位/迷雾描述大体吻合；不能据此证明原模型一定看过，能确认图内容支持有限描述。
- 新 [解码证据目录](G:/AIRTS/AI_RTS/agent/runs/20261010-background-evidence-audit-01/)：a01-select 34-39秒，25帧/3表；a01-move 56-64秒，40帧/4表；a02-draft 0-12秒，60帧/5表，全部12张表实际打开。合计另看125帧，确认选择、连续移动、三选一结束；不是对所有视频的全帧审阅。
- 原 M7/M8/M10/M11/M12 实际打开原尺寸，验证强化/资金/白色建造范围，避免缩略图漏看。
- OpenCV独立全部解码命令 rc=0，A03明确 opened=false/moov atom not found；review 三次命令均 rc=0（25/40/60帧），只是提取后另行实际查看才作证据。
- PowerShell结构化读取 metadata/events/states/frames；CIM/PID和TCP/UDP核验 rc=0；Application error查询无记录。两次初版PowerShell foreach直接管道解析失败，改为收集结果再输出后成功，未影响源数据。
- Git根及两份实际文档目标checker均rc=0；严格UTF-8/链接/围栏/行末空白及定向diff --check均rc=0。共享树956条既有状态，未reset/clean/stage/commit。

原报告SHA256：`7EBA731D5BEC9AA1DA2C8E17093078F61FE37F6FFFB1A8486F25A344EA033691`；原review：`863E7A95ED90E99E7AE339DD1EB0BB0ADD98AB7FE15CAFBCA3BB1F3DB6A12EFA`，本轮保留不改。产品抽查hash与此前一致。

## 给执行者的纠正要求

先修正原报告事实和覆盖，保留原件另出 revision，不能先按错误平衡结论改游戏。补用已有 mouse_drag/key_hold/key_release 做后台资格检查；处理建造范围已出现但虚拟指针/ghost不跟随的工具路径；每局独立证据目录、退出前poll和原因；真实开局时间计时，不按观察器t_s；边操作边录、关键动作全段实际回看。

主动发展/生产/防守/采矿/碰撞/编组/副官/菜单退局重开尚未完成，按优先级补测。任何路径受阻都交付真实部分覆盖，不用“工具不存在”掩盖漏查，也不把日志线索定成产品缺陷。**本次审计结果为 needs-review；可信现象可以保留，完整玩家验收和根因修复均未达成。**
