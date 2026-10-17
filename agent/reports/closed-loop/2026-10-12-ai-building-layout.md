# 建筑布局、资源分基地与副官事件修复

状态：**needs-review，已按用户要求移交Cursor；R23产品候选，R24验证器更正**。原任务行为已有稳定真实Match证据，独立原生终态、生命周期和自然扩张已通过；127项Godot初跑完成，78个失败项串行已完成75，严格49通过，余3项因移交停止。没有全项目champion晋级；未更新打包交付、提交或导出。此前阶段报告原样保存在[report-through-r17.md](../../runs/20261012-ai-building-layout/report-through-r17.md)，失败证据不删除。

2026-10-12 19:43：用户要求Cursor把本轮剩余工作一起接管。Codex自有父PID39680/子PID52616已核验创建时间、命令及工程路径后停止，watchdog41392正常退出；[清理证据](../../runs/20261012-ai-building-layout/cursor-handoff-cleanup.json)cleanup_ok=true。旧冻结与等待用户转达要求全部解除。[接管提示词](../../prompts/2026-10-12-cursor-takeover-building-adjutant-and-performance.md)、[当前部分审计](../../runs/20261012-ai-building-layout/handoff-audit.json)、[78项失败索引](../../runs/20261012-ai-building-layout/handoff-failures.md)。

2026-10-12 20:14：Cursor把 R25 三处已证实夹具写入主测试，并用新目录补跑，不改产品判据。[结果](../../runs/20261012-cursor-takeover/r25-fixtures/final.json)为 3/3 通过、cleaned=true。`runtime-placement` rc=0、标记命中、14.81 秒；`traditional-command-hud` rc=0、标记命中、7.34 秒；`adjutant-hud-status-discovery` rc=0、标记命中、3.28 秒。这三项目录里的 `passed` 还要求清理成功且监控源码 hash 未变。原 127 项成绩和被中断的 `match-history` 不改写，没有补造 `r24-full-absolute/final.json`。

## 实际变化

电脑玩家与副官自动建造共用C#权威选址：建筑逻辑边缘至少留5.6m，评分偏好约8m；保护生产local+Z出口，以及矿场至矿点的双向行驶通道。搜索与合法性验证有固定候选预算。footprint、逻辑radius、物理Box与导航carve维持独立语义，实测边距不是OBB净空。

基地扩张面向新资源。无新矿时不在开局家旁再摆一个基地；完工分基地补矿场、对地与对空防御，车厂/兵营/机场优先开局基地。支援数量按未覆盖的完工基地增长，在建建筑也计覆盖，避免重复下令。普通副官BLD传递位置提示，资源类由权威资源选址，显式玩家/模型位置保留。

远程自动施工以最近完工己方基地为参考，排除自身及其他在建基地：20m以内全速、20–50m连续下降、50m外0.2倍；保留小数工量。因此远基地可以造，但不能靠正在建的自己获得全速。自动施工不抢矿车做工人。

逐矿场验收发现两类实际经济链问题并修复：贴建筑Box角落时依据真实表面接触卸货；矿场赠送矿车优先在服务矿点侧安全出生，堵住首选位置仍可有限搜索换点，普通生产默认方向保持。动作延迟初始化及同步movement_finished连接顺序同时修正，目标丢失明确结束。

副官额外问题已按用户授权纳入：build_home_anchor、movement_urgent在dataclass/图状态/JSON检查点保留；seen_arrivals采用发生tick字典并迁移旧list，容量256。原生Movement结束前保存请求目标、解析目标、位置、原因和真实physics tick，DCS正常10Hz采样消费每单位最多8条终态，保留旧采样回退。到达和path_failed都关联真实时间/目标，旧段迟到事实不作废新段。断连poll后也不再查询已关闭socket。

## 改动文件与职责

| 组 | 文件 |
|---|---|
| 权威选址与远程施工 | source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs、GodotStructurePlacementWorldPort.cs；source/csharp/GodotAdapter/Composition/CommandRuntime.cs；ConstructionContracts/ConstructionService/Domain StructurePlacement相关合同 |
| 电脑基地角色 | source/match/players/simple-clairvoyant-ai/AiBuildAnchors.gd、EconomyController.gd、ConstructionWorksController.gd、OffenseController.gd、DefenseController.gd |
| 副官建造/持久化/事件 | source/adjutant_coordinator/graph/observation_view.py、task_patch.py、rules_fallback.py、state.py、graph.py、nodes.py；campaign.py仅防御口径注释 |
| 卸货/出生/动作 | source/match/utils/UnitMovementUtils.gd、UnitPlacementUtils.gd；source/match/units/OreRefinery.gd、actions/MovingToUnit.gd、actions/Moving.gd |
| 原生终态/断连 | source/match/units/traits/Movement.gd、source/net/DebugControlServer.gd |
| 回归 | tests/automated/AiBuildingLayoutSmokeTest.gd/.tscn、AiExpansionSupportSmokeTest.gd/.tscn；source/adjutant_coordinator/tests/test_state_channels.py、test_arrival_segment_correlation.py、test_graph_runtime_fake.py、test_behavior_tree.py及相关建造用例 |

以上按本轮补丁与原始文件证据描述，整个Git diff还含其他会话改动，不能把所有未提交文件据为本轮。source/match/units/Unit.gd、GeneratedTerrain.gd等外部变化只监控版本，不宣称来自本轮。最后两次产品精确补丁的原始字节/hash/mtime见[r22-peer-drain](../../runs/20261012-ai-building-layout/r22-peer-drain/before.json)与[r23-failure-correlation](../../runs/20261012-ai-building-layout/r23-failure-correlation/before.json)。

## 数值与稳定版本证据

| 项目 | 基线或期望 | 真实结果及证据 |
|---|---|---|
| 拥挤布局逻辑边距 | 原0.07996m；下限5.6m | 初始修复9.264879m；13阶段副官局8.525639m，[R21GPU结果](../../runs/20261012-ai-building-layout/r21-gpu-final-chain/result.json) |
| 普通出兵及移动 | 不陷在建筑团 | 初始布局坦克20.9001m/无人机13.2001m；R21坦克58.5745m |
| 同work100自动基地施工 | 远距0.2倍率 | 25.3526m需118ticks；105.375m需500ticks，[布局/距离探针](../../runs/20261012-ai-building-layout/r17-layout-distance/result.json)。25m已超全速边界，118不是全速100 |
| 自然电脑真扩张 | 无远矿不假扩张，有远矿补经济防御 | 当前R23独立自然局两基地81.0873m，远矿59交货/23600矿，远对空/对地各1；110.3非暂停模拟秒，生产home无违例，最小6.2482m，[独立报告](../../runs/20261012-ai-building-layout/reviewer/review-r21.md) |
| 副官逐矿场交货 | 每个矿场都必须>0，不能只看总数 | R21主矿35/14000矿，分矿2/500矿（小矿点耗尽）；13建造阶段、坦克58.5745m、重开正常 |
| 原生侦察终态 | 目标清除之后仍能观测完成 | R20真实两腿原生事件发生ticks104/148；R22/R23当前新Match两腿也通过，旧交矿/正常重开通过 |
| 副官全套 | 声明运行时测实际失败 | R23 unittest1045项：1044pass、1skip、0fail、rc0，全Python源码hash稳定 |

[R21GPU驱动](../../runs/20261012-ai-building-layout/r21-gpu-final-chain/driver.json)：PID42156，engine/driver/recorder rc0，marker/fresh_result/cleanup/source_unchanged全部true，forbidden_hits=[]。164.305wall秒；35受监控源码/场景/DLL前后hash稳定。

[R22稳定新局](../../runs/20261012-ai-building-layout/r22-s1-stable-native/driver.json)：PID28376，engine/driver rc0，原生两腿侦察+旧交矿+正常重开，marker/fresh/hash/cleanup通过。初次长局恰逢GeneratedTerrain外部更新，engine行为绿但driver1，单列不晋级。

[R23新局](../../runs/20261012-ai-building-layout/r23-s1-native/driver.json)：PID50112，engine/driver rc0，原生两腿侦察+上一腿真实到达重投故障注入+旧交矿+正常重开，marker/fresh/hash/cleanup通过，无forbidden。path_failed特定边界由独立Python反例及自身4个正反用例验证；独立正常Match真实Unreachable迟采样→Python消费者的新路线保留也已通过。

各局仍有Godot dummy texture或map_index引擎错误；严格结果按现有forbidden合同和行为断言，不冒称零日志错误。R21的一条socket !is_open已定位DCS关闭peer后的读，触发R22守卫；稳定R22/R23未见该错误。真实客户端与TCP套件的最终结果以全量记录为准。

## Python与Laya失败的归因

命令：`D:/software/anaconda3/python.exe agent/runs/20261012-ai-building-layout/python_suite.py --out agent/runs/20261012-ai-building-layout/r23-python-complete`。runner实际调用声明环境`G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe -m unittest discover -s source/adjutant_coordinator/tests -p test*.py -v`，rc0、1045tests/1skip、fresh日志、全Python与balance hash稳定：[结果](../../runs/20261012-ai-building-layout/r23-python-complete/result.json)、[日志](../../runs/20261012-ai-building-layout/r23-python-complete/unittest.log)。

此前Anaconda完整pytest的1011pass/18fail/6skip来自缺pydantic_ai的环境，其中14条Laya失败为依赖环境错误；声明运行时有pydantic-ai2.42.0/langgraph1.2.11/Laya，基线只剩4条真实失败。实际修复状态通道/到达关联；另一个防御断言要求response≥40且response<40，无法满足。替换成实际40m检测/20m局部响应/家空时最多3个召回/有家兵不继续远召回，产品半径与行为未改；保留旧远前线回归。全部Laya路由、降级、熔断模拟用例已通过，无额外Laya产品改动。

跳过1项为环境已安装Laya时不适用的无Laya真实provider分支。没有启动真实GPU小模型调用，测试绿不等于GPU推理速度或自然模型策略已验收。

## 动态录像实际查看

[110秒录像](../../runs/20261012-ai-building-layout/r21-gpu-final-chain/video/clip.mp4)，[实际回看记录](../../runs/20261012-ai-building-layout/r21-video-review/review.md)，[60秒布局帧](../../runs/20261012-ai-building-layout/r21-video-review/overview/frame-0000300.jpg)。PrintWindow只录自有PID42156/HWND396836，独立Windows desktop，5FPS550帧、0补帧、400观测变化帧，所有帧foreground=false，无音频、无系统输入或焦点激活。

已打开overview两表及60秒全帧；home40–50秒全部51帧，remote52–68全部81帧，tank100–109.8全部50帧。57.4秒分矿场完工、矿车靠矿点出生；60.0–60.6向矿场、62.8–63.0离开、63.8再靠近、66.0–66.6离开，与两次交矿数据对应。66.8秒起成长选择菜单暂停并遮挡，约90秒恢复，不当作卡住。坦克时段可见连续转向和通道行驶；只归属有数据的受控坦克位移，不凭图假定所有车辆都是同一个。

证据等级command-level；正常玩家点选/框选/右键UI输入资格未通过，音效未测，5FPS仅采集频率不是游戏帧率。R21录像源码与R22/R23不同，不能把录像当后续版本同hash复验；后续修改仅事件消费者和socket读，最新逻辑仍由新Match验证。

## 独立复核与完整回归

关键复核来自同任务独立会话，遵循[闭环规则](../../../skills/闭环验证工作法.md)要求“找另一个会话/智能体用自己的探针复现”。写入仅reviewer证据，无产品编辑/build/import或外部终止。

- R14独立512Box边界/75旧规则回退、真实角落到达通过；R15独立24方向/8无效回退、安全替代出生/封闭负向通过。
- R17独立正常移动、延迟owner、丢失目标、同步结束接口、退局重开通过；稳定生命周期PID48940 rc0。同期自然长局Unit.gd外改，行为绿但driver1，不晋级。
- [R18–R23独立报告](../../runs/20261012-ai-building-layout/reviewer/review-r21.md)：自行检查JSON十轮/256限额/重复seq/迟到arrival/真实时间/current failure/点攻击保留。原11项中旧path_failed反例1红，主线R23修复后独立12项全绿，哈希稳定。自建真实Match终态探针PID43012、生命周期PID37596、自然电脑PID29468均engine/driver rc0，166受监控源码/场景/探针及2DLL稳定，三个局共同149产品源码hash完全一致。真实终态目标清空后的延迟采样保留原tick和requested/resolved、重复采样幂等、最新8条环/独立拷贝、同名新实例不被旧游标屏蔽、移除后清空均通过；真实原生事实送Python消费者14项全绿。自然电脑35.182秒无矿负向保持1基地，正向110.3模拟秒两基地81.0873m、远矿59交货23600矿、AA/AG各1、生产全部home无违例、不抢矿车施工，两次清理units0。
- 当前纯C#隔离测试24fail与任务前逐条完全相同（production3/balance21），construction15及placement8通过，[当前结果](../../runs/20261012-ai-building-layout/r16-core-current/result.json)、[基线比较](../../runs/20261012-ai-building-layout/core-baseline-compare/result.json)。最近构建rc0、0警告/0错误；运行中未做构建覆盖DLL。
- 当前127项Godot回归：[r24-full-absolute](../../runs/20261012-ai-building-layout/r24-full-absolute/summary.json)，命令`D:/software/anaconda3/python.exe agent/runs/20261012-ai-building-layout/regress.py --ids all --jobs 4 --out G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/r24-full-absolute`。127初跑及75串行完成，严格49通过；未放宽标记或forbidden。用户移交时停止父PID39680（创建时间2026-10-12T18:30:50.164416+08:00）及MatchHistory子PID52616；最后被中断的串行MatchHistory无有效新成绩，size-unification-regression与match-end-navigation串行未启动。没有final.json，原初跑红项保留，由Cursor按需另目录补验。
- 旧full/R16full/R17full为中断阶段记录，绝不合并成当前完整成绩。R17留下53项完成产物及自有父PID49100清理身份记录，因用户扩scope后的R18补丁而停止。

已观察全量runtime-placement原点断言、structure-placement导航初始化及驱逐、资源/场景夹具、ObjectDB/RID清理等失败，先保留并单跑；未做隔离基线证明的不能统一称既有/无关。保持相关门禁失败可见，不能为全绿重写大范围导航或放宽断言。

## 共享工程、候选与未验证范围

OpenCode只读交接已确认，记录[handoff-to-codex.md](../../runs/20261011-adjutant-map-progress/handoff-to-codex.md)：session ses_ed43d89ddffewiH7AqoU1PBBLv，step-5-preview-free，16:57:47声明停止产品编辑/build/import/测试录像，只报告自己的probe脚本修正。用户说明Cursor仍工作，不能把此后所有源码/DLL变化归给OpenCode。R22初局GeneratedTerrain在开始时更新是事实；来源未完全归属。所有受控对局采用自己PID、独立端口/用户数据和清理，未终止其他会话或游戏。

用户进一步明确Cursor执行[AI卡顿与GPU优化提示词](../../prompts/2026-10-12-ai-stutter-gpu-quality-optimization.md)。其P0覆盖StructurePlacementRuntime/WorldPort、SimpleClairvoyantAI、Economy/Defense，与本轮共享代码；P1覆盖副官模型资源竞争，P2覆盖地形/GPU。不得推断Cursor已停写或替它宣称优化通过。回归与其性能采样重叠时不能认证安静性能A/B；本轮只按实局逐次hash稳定判断功能证据。

R15三次未晋级后切换动作初始化方向，R16/R17恢复旧经济链；R19原生第二arrival漏采后转向保存真实终态；R21独立反例促成R23失败关联。当前局部新/旧行为无连续失败，最近无提升计数0；整体S3仍needs-review，[checkpoint-r23](../../runs/20261012-ai-building-layout/checkpoint-r23.json)记录35文件hash、证据、限项。

性能只确认结构有界：建造有限候选，终态每单位8条、只在结束追加，DCS沿用既有采样，不增加每physics帧的全单位扫描。未完成安静同负载性能A/B，不能声称FPS改善或副官/电脑/真人大量部队CPU-GPU资源争用已全面优化。旧anchor性能夹具必须先核对当前主基地生产策略，再作有限测量。

未验证：正常玩家UI输入链、声音、真实GPU小模型推理、自发自然模型战略、大图/大部队/网络全面导航与性能。全部地图随机布局也未覆盖。后续由Cursor收口相关门禁并更新最终局部验收，不将测试绿改写为全游戏无问题。

独立复核明确限项：正常Worker从(260,230)点击兵营中心(280,230)，请求目标被clamp到建筑另一侧(284,230)，最终(276.4056,226.5036)并Unreachable。事件正确送达不代表通用建筑内点绕行已修复；不在本轮布局/状态完成结论里掩盖它。每单位8条终态溢出会丢弃更老事实，有限环不承诺任意延迟零丢失。

## 验证器环境更正（R24）

原r23-full把APPDATA/LOCALAPPDATA设为相对路径。独立同源码对照[r23-environment-diagnosis/result.json](../../runs/20261012-ai-building-layout/r23-environment-diagnosis/result.json)：relative PID34408实际OS.user_data_dir不是绝对路径，状态扫描8fail；absolute PID45312实际userdata为绝对路径，同源码0fail/rc0。FileAccess直接读取新鲜文件成功，不能证明DirAccess目录枚举正确。修复的仅是证据驱动regress.py在启动时resolve输出目录，未修改产品或扫描断言。原相对环境成绩只作诊断，不将其全部红项归给游戏。它完成127项初跑后因已确认的测量环境缺陷而停止长串行复核；父PID28376及其OreRefinery子PID18880均核验创建时间/命令后清理，[停止原因与身份](../../runs/20261012-ai-building-layout/r24-regression-environment/stop-invalid-runner.json)cleanup_ok=true。相对环境最后被中断的串行子项不算有效成绩。绝对路径的新完整回归已启动，并保留失败串行复查。

R21GPU与R22/R23真实Match驱动、声明Python完整1045及独立三局均使用绝对目录，专项成绩不受此验证器缺陷影响。

## 回归夹具对照与待落地修正（R25准备）

当前完整回归期间保持主测试只读。三条夹具问题已有保持原断言的复制对照，不将复制探针成功改写成主套件已通过。

- RuntimePlacement原“吸附原点”失败：实际Tank从(13.263,0,12.637)到(13.263,0.6,12.637)，水平位移精确0，敌建筑原位不变。原断言在贴地前抓取y=0；预期高度改取Match权威地表采样后保留原3D距离<0.01及三条断言，复制场景rc0/marker/forbidden=[]/cleanup/hash稳定。见[原始读数](../../runs/20261012-ai-building-layout/r24-runtime-fixture-diagnosis/diagnosis.json)、[高度预期对照](../../runs/20261012-ai-building-layout/r24-runtime-ground-expectation/diagnosis.json)。
- [HUD独立复核](../../runs/20261012-ai-building-layout/reviewer/hud-fixture-independent-review.md)：原基地西4m同时逻辑/根碰撞投影重叠；地图内+Z14m安全。控制ForceMove后的一个完整物理步，两局tick3到4，原局位移1.9916m进入到达容差，订单Arrived后Halt无活动订单；安全局0.275m、InProgress到Suspended，原58条条件/消息/顺序不变，2失败/0失败，rc1/rc0。此前西14m越界且未经过物理步的成功记录只作历史诊断，最终依据地图内、物理步受控证据。五局共同177文件及2DLL相同，后3局181文件稳定，无forbidden，清理通过。
- 副官HUD状态发现主测试四个Label.new未归属父节点，node.free不能释放它们；复制场景仅补节点父子归属，原状态发现和文字断言不改，严格rc0/marker/forbidden=[]/cleanup/hash稳定，见[标签归属对照](../../runs/20261012-ai-building-layout/r24-hud-label-diagnosis/diagnosis.json)。

用户要求移交后，R25原等待全部串行结束的条件解除。Cursor已按当前磁盘版本修正三处主测试：坦克预期高度改为 `ground_height_at`，基地夹具改为地图内 +Z 14 米并在原画面等待前先等一个物理帧，四个 Label 挂到夹具节点上。原断言条件、消息和顺序保留。[方向与门禁](../../runs/20261012-ai-building-layout/r25-fixture-repair/direction.md)，补跑目录 `agent/runs/20261012-cursor-takeover/r25-fixtures`。不修改游戏行为，不删断言，不通过过滤日志忽略其他 placement/navigation/退出清理失败。

WorkerGather另外两条原断言的时序已单独诊断：[卸货停留对照](../../runs/20261012-ai-building-layout/r24-worker-dwell-diagnosis/diagnosis.json)。刚入账时cargo=0、stock=0、状态UNLOADING、公共订单InProgress，卸货timer还剩1.972416秒；最多5秒的公共状态等待实际2秒后订单Completed、action=null。原测试在入账后立刻要求Completed，再等0.5秒就要求待机，早于现行2秒停留。复制场景所有原断言0失败/rc0/marker，但仍有RID/ObjectDB/resources退出泄漏，严格passed=false，不能据此把WorkerGather主套件标绿。本轮暂不修改这条主测试，不忽略其清理失败。

R24的127项初跑已完成，严格49/127通过，84项rc0且命中通过标记，其中35项仍有forbidden退出清理日志。[移交审计](../../runs/20261012-ai-building-layout/handoff-audit.json)记录新鲜产物、监控版本稳定及所有已完成自有进程清理。7个rule-ai套件与副官UI状态一致性/TCP framing/真实DCS客户端严格通过。78个失败项已串行复查75，0转绿；余3项由Cursor补验。此为移交时部分状态，不是最终通过数或全项目认证。
