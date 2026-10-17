# 战略层修复与独立测试计划

日期：2026-10-13。用户授权：主代理亲自实现，独立 AI 负责测试、视频与报告，再交主代理验收。

开发根 `G:/AIRTS/AI_RTS`；不动交付包、引擎、模型服务、venv。目标源码路径已通过主工程 develop 检查。共享文件保留基线副本/hash，精确修改，不回滚他人未提交工作。

权威来源：观测解析复用 `observation_view.normalized_units`；机动作战能力复用 `rules_fallback.combat_types_from_rules`；生产关系/价格/资源来自当次规则与 strategic 视图；玩家控制来自图状态；计划继续使用 StrategicPlan，命令继续走既有候选/仲裁/权威执行链。

实现范围：strategy_variants.py、model_context.py、nodes.py 的战略上下文参数、agent_runner.py 的变体装配和有界日志、必要的 task_patch_bridge.py 战略执行摘要；与这些改动相关的合同单测。独立 tester 不改上述产品文件。

阶段：

1. Round 01：修真实能力事实、合法候选、生产者/预算、控制权限和 KEEP。静态/合同校验后交 tester 新鲜真实 Match，过 S1 才开始下一逻辑补丁。
2. Round 02：正式可开关接线、修模板枚举混淆、记录原生选择/规则回退、候选均衡置换与请求关联。保持默认现状，验证已有配置模式及新鲜 Match。
3. Round 03：根据实测确定战略目标对执行层的实际影响。优先补已有摘要与关联证据，不新增第二指挥中心，不清空在途经济/战斗，不弱化迟到/玩家优先守卫。
4. 版本冻结：独立 AI 跑原矩阵、带敌方、跨图/seed、长局、正常退重开、玩家接管/故障、性能、后台视频实际回看及回归。主代理复核原始证据，修复独立测试证明的问题；任何硬门禁未过不得晋级默认。

基线：上一审计已复现建筑移动/生产者错误、B 10/10 规则回退、C 置换不均衡；协调器有既有失败，Godot 历史结束链有脚本错误，均需独立分类。旧结果不是本轮成功证据。

执行 tracker：`agent/runs/20261013-strategy-implementation`。验证者：`/root/strategy_verifier`，证据写入 `agent/runs/20261013-strategy-implementation-verifier`。每轮记录 hash、patch、S1/S2 结果、champion 及无提升次数。

状态：in-progress。产品 champion 尚未晋级；用户指定的测试分工不降低门禁。最终报告链接测试者的视频/报告与主代理复核结论，明确尚未通过项。

2026-10-14经济阶段：Economy01、01b均拒绝且精确回滚。01b实局已出现首矿交付，但独立审计证实截断/旧checkpoint/并行建造会误绑定工地，不能晋级。Economy01c删除全部同类建筑差分猜测，进度仅消费精确命令/工地身份，并保留runner延迟复核的完整权威结果。8产品文件冻结于 `agent/runs/20261014-strategy-implementation/economy-01c/source_hashes.json`，200相关Python断言rc0；独立边界复放及240模拟秒真实新局正在执行。当前测试代理为 `/root/strategy_verifier_01b`、`/root/baseline_verifier_01b`，证据写入各自20261014目录。未过S1/S2前不推进战略变体接线。

2026-10-14阶段决定：01c独立18边界和241.150模拟秒经济链通过，但退局10条离树表现RPC以及runner自然退出窗口硬门禁失败，整体reject、8/8精确撤回。经济方向连续3轮未晋级，切换高层方向为生命周期/通信。H04只改NetSync表现入口的离树/待删除守卫，正常autoload解析rc0且独立新鲜两局S1通过；S2和后台视频进行中。TCP长度头误读已独立复现，留待下一紧密小补丁。runner长局退出延迟继续实测，不先归因模型线程。

后续阶段：H04后台120秒/600帧与采集卸货、退局、同客户端重开通过；S2结算导航夹具修复后retest02自然rc0。match-outcome仍有三条真实建筑全灭断言失败，因此H04暂reject、只撤自身10行并核验恢复原hash，保留成功证据。下一候选O01先独立取预置单位登记时序的真实基线，修复其权威类型分类；之后从健全基线重建H04及TCP，不在未通过候选上叠改。

当前全量PowerShell runner在Assert-Manifest被既有登记/性能场景口径阻断，还未启动Godot，不可计为通过；独立tester保留原阻断证据，逐项相关套件仍使用当前marker/rc/全部forbidden判据。修复产品不以更改清单或削弱错误检查换绿，S3仍明确待验。

2026-10-13阶段调整：Round01真实S1未通过，CC非法生产任务KEEP漏检由Round01b修复；首次真实Match还暴露既有初始化/退局错误、资源泄漏及NoValidSite经济闭环失败。先做H01运行对象生命周期守卫与必要的独立小修复，逐补丁实测，不能跳过旧链硬错误推进Round02。新增baseline_verifier仅独立诊断/验证，产品修改仍为主代理；H01范围NetSession.gd、DebugControlServer.gd、Minimap.gd、AirNavigation.gd、Navigation.gd。默认不晋级。


2026-10-14 current phase: InteropId01 and H07 are locally accepted after fresh independent S1/S2 and exact diff review. H07: two normal network games34checks/73.893wall, actual refinery deliveries/live client presentation/detached boundaries/menu and same-client rejoin; six suites101.581wall, all naturalOS0/fullmarker/forbidden including Fatal0/owned0. Reports: agent/runs/20261014-strategy-baseline-verifier/health-07-s1/verification.md and health-07-targeted/verification.md; static review implementation-verifier/health07-static-review.md. Global S3 is still needs-review.

TCP01 has now been written: shared deploy/dcs_transport.py and wrappers in agent_runner.py/godot_tcp.py, plus tightly coupled top-level batch error copies bound to original intent IDs. Three AST parses rc0; source freeze157 files in implementation/transport-01/source_hashes.json. Exact frame length replaces brace searching, one send, bounded1MiB, one monotonic socket deadline, local error unknown/retryablefalse without raw response, legal authority error unchanged, other OSError preserved. This does not guarantee end-to-end exactly-once; graph replay is unchanged. No economic recovery or strategy mode change has been applied. Current independent fresh original runner main S1 is being started by tcp_runner_verifier;240sim/900wall/menu+40s naturalOS, actual public command/old movement chain, manual mine setup separately disclosed. Offline verifier and formal-test author prepare only until S1 passes. Previous subagents were no longer live after continuation, and no active test process existed; new agents resume existing evidence without overwriting it.
