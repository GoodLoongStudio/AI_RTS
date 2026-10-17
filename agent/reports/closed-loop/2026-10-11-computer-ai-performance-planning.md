# 电脑玩家性能升级：规划交付记录

日期：2026-10-11（北京时间）。状态：**complete（仅计划/提示词交付）**，产品优化未实施。

用户要求写升级电脑玩家性能的计划与提示词，供另一个AI执行；最新要求强调CPU核心/线程分配及整局优化。本次只读核查源码和本机硬件并创建/修订文档，没有修改游戏AI、线程、玩法或成品，没有启动Godot/模型服务。

## 交付

- [本地整合版执行提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-11-match-performance-overnight-integrated.md)：用户最终只需发这一份；完整包含整晚迭代、整局CPU核心/线程预算、副官共存、5 FPS录像审阅和回归交付，无需拼接历史补充提示词。
- [三阶段计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-11-computer-ai-performance-plan.md)：玩家可验收的主线程减负、首段后台决策、完整多电脑长时验收，以及线程协议和测量门禁。
- [阶段一执行提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-11-computer-ai-performance-stage-1.md)：可直接交给另一个AI，整晚完成基线、多轮单项候选及反复开局验证，不一次重写全部AI。

推荐每局共享C#有界后台决策执行器，首版1个计算并发，基于玩家合法观察的纯数据计算。主线程保留场景采集、授权、状态提交和既有Gateway执行。后台化之前先实测并减少重复工作；不承诺搬线程自动降低总CPU。

## 用户补充：整晚多局与5 FPS录像

按用户补充同步修订了计划和提示词：默认约6–8小时有效预算、末尾留60–90分钟复测；组织目标12–20局有效新Match，正式性能样本顺序运行；1AI/3AI的起始基线与最终版本至少4场正常可见对局，最终版本补长时检查。局数与时间不是成功判据，真实收益、行为与回归门禁仍优先。

应用 [动态玩法验收skill](G:/AIRTS/AI_RTS/skills/airts-temporal-playtest/SKILL.md)，核对现有record_playtest.py参数，写入5 FPS、60–120秒分段录制、1–2Hz只读状态、0.2秒关键区间实际回看、视频秒数索引与后台非干扰要求。录像用于判断游戏过程；p95/p99和短事件仍依靠独立性能/事件测量。本次没有实际开局或录制。

整晚仍限定阶段一，允许通过门禁后积累多个优化候选；某方向三轮未提升后换方向，避免误把方向饱和当整晚任务结束。最终交付增加对局索引、候选时间线、累计收益和已看视频记录。

## 用户补充：副官共存风险

仅白名单读取开发配置的backend/device键，得到 `AIRTS_S1_BACKEND=laya`、`AIRTS_LAYA_DEVICE` 留空；provider文档说明自动cuda→mps→cpu，Laya在Python内加载。`DebugControlServer._op_tactical` 主线程扫描真实单位，`AdjutantObservationRuntime` 访问权威节点；副官并非全部工作都在GPU。代码同时存在单Agent一个在途和超时后迟到清理约束，应保留。

只读 `nvidia-smi` 识别本机RTX 3080 Ti、12288MiB显存；这是硬件/即时状态，不是共存性能结果。只读当前两处Ollama `/api/ps` 均为空，但Laya不走Ollama，该结果不能证明Laya未加载或运行在CPU/GPU。未启动/停止服务、未发送模型推理请求，未查看或输出密钥；本次不能确定实际推理时device和影响大小。

已给计划第4.1节及阶段一提示词增加隔离Match下副官不挂接/正常观察/真实Laya决策/持续工作及现有回退的旧新对照，记录双方延迟、主线程、CPU/GC、GPU/显存、队列和超时。实际共存实验由执行AI完成，不能据配置宣称零冲突。本轮仍只修订三个文档。

## 用户补充：整局CPU核心与线程分配

只读Win32_Processor核验本机为AMD Ryzen 9 5900X、12物理核/24逻辑处理器；只读确认wpr.exe/wpa.exe路径存在，但没有启动trace或证明其分析链路可用。源码副官调度池max_workers=1、模型调用池max_workers=2；它们可能等待GPU/网络，不能仅凭数量认定CPU满载。模型库内部线程与引擎线程数仍待运行时核验。

计划新增第1.1节，提示词新增CPU拓扑、物理核/SMT、角色并发预算、受支持临时参数及亲和性A/B规则。基线为默认调度，电脑未来计算先1并发；本轮可测已有导航/物理和副官CPU线程预算。固定核心编号、共享.NET池永久绑定、全局限线程、填满所有逻辑核均不作为方案。若主热点是导航/移动，允许按原合同验证一个最小热点候选，避免一晚只降低小占比AI成本。

用户可验收的主结论改为整局frame尾延迟、超预算长帧或正常模拟容量有可重复改善，并保留模拟速度、命令响应、副官及玩法。只有AI分项减少时称局部收益。报告必须给角色预算和实际值、默认调度/候选对照；核心分配与整局收益本次均未实施/实测。

## 用户补充：鸟群与三种指挥者的大部队移动

只读核查了Movement.gd、UnitMovementUtils.gd、真人UnitActionsController、UnitCommandService/LegacyMovementPort及电脑Gateway/编组。现有移动是NavigationAgent3D/RVO加精确推出、地表、到达及恢复，已有默认关闭的邻居网格/交通协调FLOW实验，不能声称从零添加或直接用其Node字典上线程。终点编队与命令批量粒度目前不同，三种来源需追踪原合同。

已同步整合提示词、阶段一提示词及计划2.1节：群体路线/走廊、受约束的分离/对齐/聚合、既有安全执行的组合；共享路径/流场单独候选，空间索引密度退化和生命周期，高频移动/低频决策CPU预算，三种真实指挥链、窄口/逆向/混合单位等对照。方向属待测候选，未实现鸟群、未开启FLOW、未运行对局，不能保证收益。

本轮源码检查发现Gateway等文件已有新的共享树修改，未触碰游戏源码，也不能把早先mtime结论外推到现在的全树。文档改动范围扩为计划、两个提示词及本报告；执行AI重读实际版本并保护已有工作。

本轮静态核验4份文档、5个本地链接、8个移动相关套件ID以及真实源码入口，整合版与阶段一正文一致；独立UTF-8/围栏/空白检查与git diff --check均rc=0。无运行时性能、录像或算法收益证据。

## 用户最新偏好：保守优化，鸟群不设为交付要求

已在两个提示词和计划2.1节同步优先级：先减少现有导航/RVO链路的实测重复工作与CPU争用，保持原算法/行为；Boids仅作为有瓶颈证据、保守收益不足且时间够复验时可选的小原型，默认关闭。安全/订单/到达回归立即拒绝，无收益最多两轮便回到保守方向；不尝试鸟群或拒绝原型均不影响其他有效优化的交付。

本轮仍仅修订4份Markdown，没有改移动算法、开启FLOW或运行游戏。整局性能收益、副官共存、5 FPS实战和回归要求继续成立，不以保守选择为由降低验收。

## 静态证据

电脑入口 `source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd` 及5个Timer控制器，编组另为AutoAttackingBattlegroup。AiCadence已有按电脑人数缩放周期；battlefield_scan已有按物理帧缓存。

GodotWorldObservationRepository.CaptureShared已按物理帧共享全场快照；Capture仍读取SceneTree/节点和当前业务状态。WorldQueryService调用采集并维护_lastKnownBySession，不能直接从worker调用。WorldQueryRuntime转为Godot集合；RuleAiCommandGateway有稳定ID、固定玩家与可见敌人授权。该事实支持规划分层，不能证明某一项已是当前最贵热点。

现有通用多线程计划 `agent/plans/2026-10-09-multithreaded-performance-plan.md` 已覆盖移动/导航大部队。本次计划限定电脑规则决策，不重复把该通用任务当作AI已经优化，也不采用旧FPS数字为新基线。

## 文档验证及限制

- `git rev-parse --show-toplevel`：主工程G:/AIRTS/AI_RTS，rc=0。
- `check_workspace_target.py --mode develop`：主工程及3个新文档实际目标均rc=0。
- 已阅读工作区边界、闭环/RSI、performance skill及measurement/cpu参考，核对真实文件路径与当前mtime/status。
- 文档链接、提示词必读文件和源码入口存在性，以及UTF-8、代码围栏和空白检查：收尾静态校验rc=0。`git diff --check -- <三个文档路径>` rc=0；因文档尚未跟踪，另用Python逐文件检查，避免Git未检查新文件的空白。
- 本次文档写入范围为计划、阶段一提示词、本报告与最终新建的本地整合提示词，均为Markdown。初次交付收尾核验的11个AI/查询/Gateway源码文件mtime与前次记录一致，Economy/Defense/Offense Controller的已有修改状态保持一致。未保存本任务开始前的源码hash，因此不声称完成了前后hash对照，也不据此证明整个共享树没有其他人写入。最终整合版另外检查正文与阶段一提示词的完整对应、UTF-8、空白/围栏、必读路径和链接，未运行游戏或模型。
- 初次盘点共享树1047条状态记录，收尾为1054条，说明不能用全树数量认定本任务写入范围。AI的Economy/Defense/Offense Controller已有他人改动，本次未触碰；执行AI必须重新核查，不覆盖共享工作。

性能基线/新数值、线程CPU画像、截图/录像、dotnet build、Godot实战、相关/全量回归与独立产品复核：**本次未运行**，因为用户要求文档规划。performance skill明确允许文档交付说明未跑项；后续实现必须按计划实测。

本次没有产品candidate/champion晋级，无产品优化轮次（连续未提升计数不适用）。三个阶段均待执行，不把规划完成写成性能升级完成。
