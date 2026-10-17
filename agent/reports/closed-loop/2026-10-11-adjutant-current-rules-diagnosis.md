# AI 副官经济、基地布局与指挥诊断交接报告

日期：2026-10-11
状态：`diagnosis-and-handoff`，不是游戏修复完成。本轮读取源码和用户已有对局日志，更新计划及整合提示词；没有修改游戏代码、没有启动新对局或新录制。

## 交付文件

- [可直接交给 DeepSeek 的整合提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-11-adjutant-current-rules-repair-deepseek.md)
- [三阶段玩家验收计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-11-adjutant-current-rules-repair-plan.md)
- [冻结日志统计与源码 hash](G:/AIRTS/AI_RTS/agent/runs/2026-10-11-adjutant-rules-audit/evidence.json)
- [只读证据统计脚本](G:/AIRTS/AI_RTS/agent/runs/2026-10-11-adjutant-rules-audit/audit_existing_logs.py)
- [本轮文档校验记录](G:/AIRTS/AI_RTS/agent/runs/2026-10-11-adjutant-rules-audit/document-validation.json)

## 当前工程与运行身份

确认开发 Git 根为 `G:/AIRTS/AI_RTS`。读取仓库 AGENTS、边界技能、manifest、闭环/RSI、动态试玩和性能规则。三个交付文档本次修订前都通过 develop 目标检查 rc=0；证据目录按仓库规定写入 `agent/runs`，它属于 operational，不是 develop 源码目标。

此前本轮只读进程盘点：Godot PID 34352，命令明确 `--path G:/AIRTS/AI_RTS`；Python PID 6652及子进程16272 的 bootstrap 将 `G:/AIRTS/AI_RTS/source` 加入 sys.path，并使用 real/langgraph、authority port 24579。它证明当前源码入口，不能单靠引导证明每个已加载模块的内存 hash。

日志 Match 为 `0eb67e68-5ebe-4c3c-82d4-e9fd332d6009`，Player_0；rules_version 为 `f2622dc726b6bba986f027b1b7113c84252171aa9f05c7e6f84ab7ab75ed309b`。日志位置：

- `C:/Users/Administrator/AppData/Roaming/Godot/app_userdata/Open RTS/adjutant_logs/agent_runner_20261011_163331_0eb67e68.jsonl`
- 同目录 `agent_runner_events_20261011_163331_0eb67e68.jsonl`
- 同目录 `archive_0eb67e68/rounds.jsonl`

读取固定字节前缀并截到 tick 28454，保存前缀长度/hash；统计脚本不连接游戏、不发命令、不调用模型。旧局统计是本次诊断证据，不能作为未来补丁生效证明。

## 已确认：当前规则和提示没有完整跟上新经济

日志确认 `laya_loaded`，模型 `convaiinnovations/laya`、device CUDA、status ready；同局有战略模型降级。开局建造来源是 baseline_policy。结论是当前规则/模型上下文适配存在问题，不能笼统断言没有接好 Laya。

| 唯一接受建造 | tick | 实体 |
|---|---|---|
| 第一兵营 | 17302 | Unit_2 |
| 第二兵营 | 17759 | Unit_3 |
| 第一车厂 | 17967 | Unit_4 |
| 第二车厂 | 18350 | Unit_9 |
| 防空炮塔两座 | 19336 / 19539 | Unit_22 / Unit_24 |
| 对地炮塔两座 | 19750 / 19966 | Unit_29 / Unit_34 |

按 command_id 去重，包含 accepted replay。第二车厂首次回执曾为 BadReceipt，后来重放确认接受；忽略重放会漏计真实建造。没有证据证明重放本身重复生成建筑。

截至该截点，802 轮归档观测均没有 ore_refinery。初始观测为基地+无人机、零矿车、资金10000。当前阶梯却以兵营开始，上限为两兵营、两车厂，随后防御，再考虑矿场；矿场分支仍要求远端新矿。它能解释双兵营及经济启动错位，无需假定建造去重已坏。

定位入口：

- [规则阶梯与数量上限](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/rules_fallback.py:134)
- [经济尚未启动判定](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/rules_fallback.py:1374)只围绕矿车/可生产设施，需核对矿场依赖与保留预算。
- [矿场远端扩张分支](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/rules_fallback.py:3996)，仍写“贴基地盖矿场没有收益、工人本来就在基地采”的旧口径。
- [campaign 主线](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/campaign.py)，M01 不等于真实交付成功，M08 为远端分矿；需建立首次采矿目标。
- [战略系统提示](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/pydantic_agents.py:328)仍写“指挥中心造工人”。
- [Laya 发展候选](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_patch_prompt.py:66)的 KEY_BUILDINGS 及后续建造菜单不含矿场；菜单有截断预算，经济前置必须优先入选。
- [战略上下文](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/model_context.py:158)包含摘要及 rules_available 布尔；需复核实际传给模型的规则语义，不能把布尔/hash当生产链说明。
- [当前经济手册](G:/AIRTS/AI_RTS/docs/ai-adjutant-handbook/02-opening-and-economy.md)及 [矿场权威实现](G:/AIRTS/AI_RTS/source/match/units/OreRefinery.gd)规定真实完工赠矿车、车厂生产后续矿车、向矿场交付。service_radius_m 当前已经不参与玩法；不能恢复过时半径门槛。

修复要求是阶段目标、经济预算、模型候选与回退一起更新，首次矿场与远端扩张分开；允许有理由的紧急防御，不以首笔交付锁死所有军事动作。有效建设计数使用身份关联集合，后期扩产仍保留。

## 已确认选址倾向，持续堵塞仍待动态复现

最新截图确有密集围绕主基地的两车厂、两兵营和炮塔布局。源码显示：

1. [自动候选锚点收集](G:/AIRTS/AI_RTS/source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs:379)遍历玩家子节点，只要求 unit_type_id 和正半径，没有过滤移动单位；文件另一个 OwnStructures helper 则过滤 MovementObstacle。移动单位是否实际影响本局落点需测量，它不能因此扩大权威建造网络。
2. [最优先贴建候选](G:/AIRTS/AI_RTS/source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs:406)使用 `own.Radius + radius + EdgeClearanceMeters*0.5`。EdgeClearance 为0.75m，逻辑边缘余量0.375m；[首个合法点立即返回](G:/AIRTS/AI_RTS/source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs:423)。这能确认“优先贴建”的策略，不是实际 hull 通道宽度测量。
3. base/resource 模式先尝试全局贴建层，可能覆盖调用方资源 hint 的战略意义；hint 模式跳过这层。需用实际 requested→accepted 坐标复现。
4. [当前建造网络范围](G:/AIRTS/AI_RTS/source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs:45)为边缘最大12m；它是最大合法范围，不是要求建筑紧贴的最小间隔。该端口明确建造不受战争迷雾限制。
5. [权威服务过滤 BlocksPassage](G:/AIRTS/AI_RTS/source/csharp/Application/Construction/StructurePlacementService.cs:125)，世界端口也允许窄缝；LeavesBlockingGap 留存但不参与评估。合法放置并不提供自主基地布局的通畅保证。

执行提示词要求在合法点中做有界自动布局，测量各类 hull/footprint/carve/agent，保护基地出口、生产出生和矿车往返。保持玩家手动窄缝放置、12m建造规则和受限通行合同，不通过缩碰撞或扩大穿模修复。

需主动复验的相关风险：

| 风险 | 静态线索 | 未验证部分 |
|---|---|---|
| 工地完工后封路 | 建筑障碍/导航更新随完工发生 | 当前截图中哪条路线持续被封、影响哪些单位 |
| 出生落入孤岛 | 共享 [production_spawn_spot](G:/AIRTS/AI_RTS/source/match/utils/UnitPlacementUtils.gd:141)找安全落点 | 生产单位是否能从该点走出，而不是仅落点合法 |
| 矿场赠车失败无恢复 | [赠车函数](G:/AIRTS/AI_RTS/source/match/units/OreRefinery.gd:107)失败重置标志，但源码搜索只有 constructed 调用 | 动态失败后是否存在外部恢复；需真实 build 完工、无落点→释放通道后测试 |
| 自动施工/军令占用矿车 | 副官建设载体和军令共享控制集合 | 是否打断有效采集循环、是否需重新接管 |
| HUD状态混示 | 截图同时“等待挂局”和战术降级结果 | 是短暂重启/过渡还是心跳/旧Match状态错误，须对齐PID、Match与时间 |

## 移动统计修正：主要短点在主力推进

以同 tick 归档观测的位置，计算接受 intent 目标的 XZ 直线距离；按 intent标识归为侦察/推进，去重已接受意图。此口径不是导航路长、实际旅程、到达率或中途取消证明。

| 类别 | n | 最小 | 中位数 | p95 | 最大 |
|---|---|---|---|---|---|
| 侦察 | 158 | 13.69m | 74.27m | 214.09m | 473.56m |
| 推进 | 1857 | 3.72m | 13.20m | 14.29m | 16.36m |

例如 tick18268 的 Unit_6，从同tick观测 `[115.2,92.2]` 到目标 `[106.12,94]` 为9.26m；相邻两目标之间的差值不能当实际一步行程。初稿的“23.4m/9.4m实际短跳”和“侦察普遍只有10m”已撤回并在交付文档中修正。

- [主力中继默认值](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/movement.py:61)为14m；[hop_limit](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/movement.py:739)受 radius 和 own_sight 的较小值限制。与推进统计相符，是优先验证的策略原因；最终段长仍需实际路径/安全/到达A/B。
- [侦察ROLE_SCOUT](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/movement.py:901)通常绕过此中继；[行为树侦察](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/behavior_tree.py:571)有 state 时用 explore_frontier，10m ring只用于兼容分支。
- [hop_in_progress复用](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:2405)和 fallback 的 en-route守卫已存在。不能凭接受命令频繁就认定尚未到达被不断打断。

提示词要求长期战略目标与安全执行段分离、保留途中目标、测实际路长/覆盖/到达/查询次数。不引入Boids，不重写整个移动系统。

## 截图与验收范围

本轮打开查看用户截图，并原样保存三张，副本hash与原图一致：

- [开局两兵营](G:/AIRTS/AI_RTS/agent/runs/2026-10-11-adjutant-rules-audit/screenshots/01-opening-two-barracks.png)：建筑卡为两兵营、一车厂，未显示矿场数量。
- [部队命令标记](G:/AIRTS/AI_RTS/agent/runs/2026-10-11-adjutant-rules-audit/screenshots/02-troop-orders.png)：短橙色目标和长青色路线同时存在，不能单凭标记泛化所有路线都短。
- [密集基地](G:/AIRTS/AI_RTS/agent/runs/2026-10-11-adjutant-rules-audit/screenshots/03-dense-base.png)：基地周围密集建筑与单位，余额100，HUD同时显示等待挂局与战术回退。单帧39FPS不是性能基线，单帧拥挤不是持续堵塞证明。

新修复由DeepSeek按三个可试玩阶段验收：A经济+布局+出兵/采矿通行，B侦察+主力持续推进，C正常/降级/接管整局及性能。每阶段内遵循RSI多轮、每关键补丁新真实Match和旧链路回放，后台5FPS录像实际回看；终局须全量回归和独立复核。

## 本轮校验、未运行项和并行风险

### 后续需求补充：无人机应承担主要探图

用户新增要求副官更主动造无人机，不能主要用小兵探视野。已将生产前置、预算、增补、战损替补与多方向分工加入同一计划和提示词的阶段 B，没有新增审批阶段，也没有修改游戏代码。

静态确认：[RECON_MIN_PROBES](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/rules_fallback.py:688)当前为1；[recon_produce_intent](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/rules_fallback.py:691)依赖已有可用空闲机场，一架现役已满足最低配额就不增补。调用位置仍位于发展规则阶梯中，实际是否被前面的分支挡住需新局追踪。现有 scoutconfirm 会定期抽作战单位确认扫描，不能一概当成错误，但应核验无人机覆盖已充足时是否无谓抽兵。

[当前demo配置](G:/AIRTS/AI_RTS/config/balance/demo.balance.v1.json)的无人机为空中单位、无武器、视野40m，成本200A、生产者仅机场；机场1200A。是配置静态事实，未来新局用权威规则核验，未用旧10m注释作测量。现有 [ReconReplacementTest](G:/AIRTS/AI_RTS/source/adjutant_coordinator/tests/test_development_ladder.py:671)主要验证最低一架缺口补充，不能替代多机主动发展验收。

修复指令要求经济稳定后按探图需求主动增补，512m地图先试验两机分方向；目标数与上限用覆盖收益/预算/风险定，不无限生产。机场前置、队列优先级与经济预算要协调；现役/队列/在途关联去重，损失后补充，防空方向避免反复送死，玩家接管不夺回。小兵侦察作为应急/局部确认，保留军队主任务。模型正常与降级均须通过真实生产→首飞→新覆盖验证。

新增代码/配置审计记录：[drone-recon-source-evidence.json](G:/AIRTS/AI_RTS/agent/runs/2026-10-11-adjutant-rules-audit/drone-recon-source-evidence.json)。本次仍为文档改动，文档校验记录刷新后为rc=0；无人机新策略、试玩、录像及性能效果均未执行，无新玩法数值或champion晋级。

| 命令/检查 | rc或结果 |
|---|---|
| `git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel` | 0，正确主工程 |
| `python tools/check_workspace_target.py --mode develop --target <三个交付文档绝对路径>` | 各0，本次修订前核验 |
| `python agent/runs/2026-10-11-adjutant-rules-audit/audit_existing_logs.py` | 0，802轮、无矿场、8条唯一建造；只读旧局日志 |
| 文档UTF-8/空白/本地链接、统计脚本AST、证据数值及截图hash检查 | 0，具体见 document-validation.json |
| `git diff --check -- <三个交付文档>` | 0；文件未跟踪，另做实际内容校验，未把diff空输出当完整验证 |
| 游戏编译、玩法测试、新真实Match、新视频、性能对比、独立游戏复核 | 未运行；本轮无游戏代码改动，RSI允许文档任务跳过Match |

实际修改仅三个交付文档和运行证据统计脚本，生成证据JSON、校验记录及截图副本。没有玩法新数值、没有游戏candidate/champion晋级；连续游戏未提升轮数不适用。所有行为改善仍待执行，不能称“已经修好”。

工作区有大量他人/历史未提交修改；已保留，未reset/清理/触碰用户Godot、Python或Ollama进程，未修改打包版。源码hash记录只代表读盘时状态，后续执行仍须复核mtime与实际加载版本。整组交付覆盖已知问题与相邻失败链，不承诺穷尽未知bug。
