# 发给 Cursor：立即接管建筑、副官收尾与对局性能优化

> **新增用户重点：** AI副官基于完整全局态势提交稳定大目标，再由Laya/战术层持续执行；程序约1秒检查局势、战略目标先按10秒复核，验证后评估5–10秒，重大事件提前触发。先解决战略等待阻塞执行，复核可以维持原计划。请同时读取并执行 [战略层与 Laya 指挥纪律补充提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-cursor-strategic-layer-laya-command-discipline.md)。它补充本提示词的产品要求，优先修复战略失焦、计划抖动和部队无目的乱跑；改动按现有架构内的中等规模实施，不直接改频率或重写全部系统。

用户已决定让你接管 Codex 本轮剩余工作，并继续原性能优化。请实际实现、测试并交付，直接从当前磁盘版本继续。

**旧协调提示词 `G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-cursor-building-regression-coordination.md` 的暂停写入、冻结构建、等待 Codex 回归、等待用户转达解冻等要求全部解除。本提示词取代那些协调要求。Codex 已停止本轮测试和产品编辑，你现在可以修改、构建和开局验证，不需要继续等 Codex，也不要把轮询旧 PID 当作下一步工作。**

## 1. 已交接的现场

- 开发根：`G:/AIRTS/AI_RTS`。保留当前全部未提交改动；先重读当前文件、diff、mtime 和源码/DLL hash，不恢复你开始任务时的旧快照。
- Codex 自有完整回归父 PID39680（创建于2026-10-12T18:30:50.164416+08:00）和当时子 PID52616 已按创建时间及完整命令核验后停止；watchdog PID41392 已正常退出。PID以后可能复用，不凭数字杀进程。
- 停止证据：`G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/cursor-handoff-cleanup.json`，cleanup_ok=true；这是用户要求移交导致的中断。
- 全量初跑127/127完成，78个失败项已有75个完成串行复查，严格通过数仍为49。剩余串行项是 `match-history`、`size-unification-regression`、`match-end-navigation`；第一项在运行中被移交中断。
- 当前审计：`G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/handoff-audit.json`；可读失败索引：同目录 `handoff-failures.md` 和 `.json`。已完成尝试的新鲜度、清理、监控源码hash均通过。84项rc0且有标记，其中35项仍有forbidden清理输出，不能把84称为严格通过。
- 没有 `r24-full-absolute/final.json`，完整串行并未结束；不要伪造final、把中断项算通过或改写原日志。原成绩与后续补验分开保存。

先读工程 `AGENTS.md`、`skills/airts-workspace-boundaries/SKILL.md`、`agent/manifest.json`、`skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md`。性能部分再读 `skills/airts-performance-optimization/SKILL.md` 和对应 measurement/cpu/render 参考页，动态验收读 temporal-playtest skill。

定位检查：

```powershell
git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel
git -C G:/AIRTS/AI_RTS status --short
python G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target <实际文件绝对路径>
```

不 reset/clean，不覆盖他人改动，不迁移工程，不动打包版，不清空 `build/adjutant_runtime` 或副官虚拟环境。只清理自己核验身份的进程。Codex 已退出这轮写入和测试；若发现其他任务竞争，只记录实际身份与负载，不重新建立一个“等Codex确认”的阻塞条件。

## 2. 先完成可直接落地的收尾

原闭环报告：`G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-12-ai-building-layout.md`。计划、checklist同名。剩余收尾由你负责，这些文档也可以更新，但保留历史轮次和证据。

R25三处主测试修正已经完成复制对照与独立诊断，**尚未修改主测试**。先核对当前代码及 `agent/runs/20261012-ai-building-layout/r25-fixture-repair/before.json`，再精确落地：

1. `tests/automated/RuntimePlacementSmokeTest.gd`：预期Tank位置抓在贴地前，y=0，实际地表y=0.6、XZ位移为0。对捕获的expected位置补 `expected_tank_position.y = match_instance.ground_height_at(expected_tank_position)`，保留原三条3D距离断言与0.01容差。对照证据在 `r24-runtime-fixture-diagnosis/diagnosis.json` 和 `r24-runtime-ground-expectation/diagnosis.json`。
2. `tests/automated/TraditionalUnitCommandHudSmokeTest.gd`：原基地西4m与坦克重叠，ForceMove提前完成，Halt已没有活动订单。把该夹具基地改到**地图内+Z14m**；ForceMove原 `process_frame` 等待之前加 `physics_frame`，观察完整物理步；原58条断言条件、消息和顺序保持。不要使用越界的西14m方案。独立报告：`reviewer/hud-fixture-independent-review.md`。
3. `tests/automated/AdjutantHudStatusDiscoveryTest.gd`：四个Label.new裸节点未随fixture释放，逐个加入fixture父节点 `node.add_child(label)`，使 `node.free()` 统一释放；保留原状态/文字断言。对照：`r24-hud-label-diagnosis/diagnosis.json`。

上面证据目录均相对于 `G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/`。这些是修正已证实的夹具前提，不能借机放宽产品判据或过滤退出泄漏。

可以直接使用 `agent/runs/20261012-ai-building-layout/regress.py`，以**新的绝对输出目录**补跑对应ID。R25的 `run_fixture_replays.py` 旧guard要求完整回归final存在；本次合法移交没有final。若使用该辅助工具，按已停止的handoff/cleanup记录精确更新guard并保留原因，或直接用regress.py；不要为了过guard伪造final。

参考补验命令，运行前先读runner参数并核对本机解释器和引擎：

```powershell
D:/software/anaconda3/python.exe agent/runs/20261012-ai-building-layout/regress.py --ids runtime-placement,traditional-command-hud,adjutant-hud-status-discovery --jobs 1 --out G:/AIRTS/AI_RTS/agent/runs/20261012-cursor-takeover/r25-fixtures
```

必要时在新目录串行补查余下3项。已完成的75项不因移交而全部从头重跑；修改产品后，按受影响范围及最终仓库门禁决定新的回归。保留现有78条失败索引，逐条区分真实行为问题、夹具/环境问题、已证明的基线失败及证据不足。

**不要要求把所有历史红项逐个修绿才能开始性能定位。** 原任务相关的真实回归必须处理，未证明原因的红项继续记录，相关门禁失败时不得晋级；性能诊断和基线采样仍可推进。最终遵守工程验收要求，没有足够证据时明确标 needs-review，不能宣称全项目通过。

## 3. 保留已验证的产品行为

- 电脑和副官共用权威选址：建筑逻辑radius边缘gap至少5.6m，偏好约8m，保护生产local+Z出口及矿场↔矿点双向通道。逻辑边距、物理Box、footprint与导航carve语义不同，不能互换。
- 分基地用于新矿扩张及防御；新矿距离条件≥30m，无新矿不家旁假扩张；完工分基地补矿场、对空/对地，普通兵营/车厂/机场留开局基地；在建也计覆盖，避免重复下令；不抢矿车施工。
- 自动施工按最近完工己方基地计距，排除自身与在建基地：≤20m全速、20–50m连续减速、≥50m为0.2倍，保留小数工量。
- Box表面接触卸货；矿车优先在服务矿点侧安全出生，受阻有限搜索替代点；普通生产方向保持。
- MovingToUnit延迟初始化owner、目标丢失守卫；Moving先连接终态信号再dispatch，避免漏同步完成。
- build_home_anchor、movement_urgent经副官图通道/JSON/checkpoint保留；seen_arrivals按发生tick字典迁移旧list，容量256。
- Movement清目标前保存真实tick、requested/resolved/位置/终态；每单位最新8条；DCS沿正常10Hz采样发布，按实例+序号消费，移除清游标。上一段迟到arrival/path_failed不能结束新路线。环溢出不承诺任意延迟无损。
- DCS poll断连后不查询已关闭socket。保持正常生命周期、退局重开和资源回收。

可复用证据与边界：

- `r23-python-complete/result.json`：声明环境 `G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe`，1045项、1044pass/1skip、rc0，Python与balance hash稳定。Laya路由/降级/熔断为模拟测试通过，实际GPU小模型未测；Anaconda缺依赖的旧14条红不等于当前产品故障。
- `r21-gpu-final-chain/result.json`：主矿35次/14000、远矿2次/500（矿点耗尽），逻辑gap8.525639m、坦克位移58.5745m。110秒5FPS已回看，见 `r21-video-review/review.md`。证据是command-level，无正常鼠标UI/声音资格，5FPS是录像采集率。
- `reviewer/review-r21.md`：独立自然电脑真实Match两基地81.0873m，远矿59次/23600，对空/对地各1，生产home无违例，最小gap6.2482m；原生终态与生命周期独立局通过。
- 当前C#隔离24fail与任务前逐项相同（production3/balance21），construction15和placement8通过；不能把这个证明推广到其他Godot红项。
- WorkerGather入账后还有约2秒UNLOADING，bounded5秒等待可达到Completed/action=null，但复制场景仍有退出泄漏；不能只改等待就宣布整套绿。local-avoidance旧RVO断言尚无合格基线归因；protocol退出AccessViolation也未根因确认。
- 独立导航残项：Worker从(260,230)点兵营(280,230)，目标clamp到(284,230)，终止(276.4056,226.5036)且Unreachable。事件正确送达不代表通用绕建筑导航已修复；别掩盖这类残项，也别顺势重写全导航。

## 4. 原性能任务继续完整实施

继续执行 `G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-ai-stutter-gpu-quality-optimization.md` 和同名计划。P0规则AI同步长任务、P1副官模型资源竞争、P2保画质GPU优化都要收口。

- 先测当前真正热点。选址/仲裁/导航若是内层同步扫描，必须控制内层成本或安全分批，不能只在外面套一个时间预算。CPU占用高低不是唯一目标，还看主线程长帧、命令延迟、模拟秒/墙钟秒及行为。
- 查本机实际CPU拓扑与线程池、模型后端、GPU/显存负载，给游戏主线程/渲染/physics留余量，限制副官与后台计算的并发和请求频率。分配方案先测再定，不按总线程数把所有核塞满，也不靠固定绑核掩盖热点。
- 规则AI或寻路外移只考虑稳定纯数据计算；明确快照、版本、取消和主线程提交。SceneTree、节点变换、导航/渲染对象不得随意跨线程。电脑、副官、真人指挥的部队继续使用同一权威执行链。
- 模型GPU推理与游戏渲染必须同开验证，记录调用时段和显存峰值，避免CPU线程池/显存抢占造成长帧。不得关副官、减单位、降physics tick/模拟速度或画质获得最终成绩。
- 保守优化移动和邻域查询，不直接重写成完整鸟群算法；只有热点和实局证明收益时才引入局部空间索引、批处理等候选。
- 安静性能A/B时别同时批量回归/编译/导入/录制压力实例；录像另开行为验收窗口。核验实际竞争进程，污染样本不计收益。5FPS录像用于建造、出兵、交矿、侦察过程判断，并实际回看对应时段。

每轮一个可验证假设，保存champion/hash，精确补丁后立即编译或解析、新开无头真实Match、重放受影响链及至少一条旧功能轨迹；失败拒绝该候选，勿在坏版本继续堆优化。性能同地图/种子/相机/画质/负载比较，小规模及压力规模均测。记录p50/p95/p99、长帧次数/最长帧、热点耗时与调用数、模拟速度、命令延迟、CPU/GPU/显存、清理与行为计数。

后台测试/录像不抢焦点、不注入系统输入；辅助控制台隐藏。正常玩家UI若未验证，明确证据等级，不把DCS接受命令当鼠标验收。

## 5. 最后交付

更新建筑/副官闭环报告与原性能计划/报告，写明本次接管、R25实际主测试结果、剩余问题、每轮candidate/champion、最终源码/DLL hash和未验证项。保留全部历史失败证据及移交中断原因。

给用户可检查的结果：布局/分基地/逐矿场采矿/生产通行/远距施工/副官事件的现版本数据及相关回归；性能原始与新数值、CPU/GPU任务分工、模型同开实测、录像实际回看记录。未通过的门禁如实标needs-review，不以平均FPS或复制夹具的成功代替整体验收。

收到后直接重读现场并开始收尾与优化。Codex的等待条件已解除，本轮不会再并行修改产品或启动验收进程。
