# Debug TCP 生命周期修复闭环报告

日期：2026-10-11。状态：**needs-review，不宣称全部完成**。实际源码根 `G:/AIRTS/AI_RTS`；目标边界检查 rc0，Git root rc0。打包成品、用户运行实例和OS输入未操作。

## 变更与不变量

- `G:/AIRTS/AI_RTS/source/net/DebugControlServer.gd`：poll刷新后检查状态，错误/断开同步回收buffer，survivors线性压缩替代逐个Array.erase；保留原有并行差异。
- 上限：128连接、每peer 1MiB字节缓存、每peer每帧读取64KiB、全局256/peer16请求预算。连接满留在TCP backlog，合法完整行排队不丢弃，轮转处理；超限未终止行明确返回request too large后断开。
- 字节缓存只在完整newline后解码UTF8，避免多字节字符跨read损坏。JSON行请求和put_utf8_string长度前缀响应不变，白名单/权限/副官语义未改，无复用/idle timeout掩盖poll根因。
- 截图最多16排队，满时明确retryable错误；无绘制帧也清理断开的截图引用，capture前poll/状态检查，不再为已死client做GPU读回。请求后_current_client置null。
- 专用工具：`G:/AIRTS/AI_RTS/tools/dev/debug_tcp_match_fixture.gd`、`.tscn`、`debug_tcp_lifecycle_probe.py`。真实正常Match+PlainAndSimple 512图、正常开局2实体；无假Match。夹具正常自动选择augment合法offer防无人测试草案永久暂停；选中组注入仅command-level证据，不冒称UI输入。
- 候选DCS SHA256 `802e58a92df7e5e623ff68d63f1bac43b52fa37c34430a1e202032975d66e172`，保存完整含既有diff `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/current-diff.patch`。

## 测量结果（measured，非同场景可见A/B）

原审计用户局约11100残留对象、空扫描22.2/22.7/22.7ms；debug_process平均25.771ms/帧。该用户局46实体，不能与本轮2实体headless直接当性能A/B。

本轮真实Match 10000/10000完整合法短连接响应、77.897s，8并发。请求结束5次采样 clients/buffers均1/1（perf查询自身占1），无历史请求数量增长；静态内存240.7→241.9MiB。

|窗口|debug_process p50 ms|p95 ms|p99 ms|
|---|---:|---:|---:|
|压力前64帧|0.02|0.33|2.67|
|压力后5个64帧窗口|0.02–0.05|0.31–0.46|0.44–1.01|

本轮客户端wall latency p50 60.35 / p95 63.40 / p99 558.18ms，包含8线程排队与Windows发送前端口退避，不能作为纯服务端命令延迟。未使用physics_script_ms作为独占脚本计时；该口径包含等待。新增debug_process计时使用真实函数包围，64样本环p99精度有限，保留原始数据，不预报400FPS。

## Requirement → Evidence审计

|要求|证据与判定|
|---|---|
|规则、边界、当前diff/mtime|已读任务/AGENTS/边界/manifest/RSI/闭环/性能measurement/audit；目标rc0；DCS原mtime10/9已有大量差异保留|
|最小网络生命周期、线性回收|上述DCS补丁；没有修改寻路/画质/单位系统|
|关键补丁解析/编译|`dotnet build G:/AIRTS/AI_RTS/OpenRTS.sln --no-restore --nologo` rc0，0warning/0error；新真实Match无DCS解析错误。`--check-only --script DCS`因autoload NetSession上下文rc1（不作通过）；`--editor --quit`rc0但import/cache污染，不能作全项目干净证据|
|真实Match至少10000完整短连接|`python G:/AIRTS/AI_RTS/tools/dev/debug_tcp_lifecycle_probe.py` rc0；probe.json stress.success=10000；launcher53132/实际36800；正常Match真实单位|
|连接buffers稳定、内存/维护耗时|probe.json samples上述数值；before瞬态clients2/buffers1是派发中survivor尚未assign，不作稳态不一致|
|持续/半包/多行|12次UTF8多字节中间切包，每次完整响应；同连接300行全部响应，超过peer预算合法行未吞|
|异常断开重连|半JSON断开后下一status正常|
|buffer上限|1MiB无newline明确request too large+limit_bytes|
|请求预算背压|300行分帧处理全响应；未测128连接饱和TCP backlog和恶意不读响应send压力|
|截图/current client|17排队第17queue full retryable；关闭client后无headless draw待截图清0。未测可见成功截图/客户端跨帧输出顺序和退出同步清理|
|真实副官探索移动|通过TCP adjutant_intent scout→move受理，正常单位实际位移15.244m。固定命令回放，不调用收费模型；不是runner决策能力验收|
|玩家选中接管|测试夹具selected_units组→正常_sync_selection_control→后续意图PlayerOverride。仅command-level；未实测玩家点选/框选GUI和持续视频|
|退出第二局|同一拥有实例拆除Match再正常创建第二局，match_id 80792049…→88324435…，2实体；自然退出rc0。不是大厅按钮/联网房间退出链路|
|只清理自己PID|自然退出；异常轮仅拥有launcher PID树；CIM核验36800/53132/15968/36472/50900/3408均已不存活|
|可见同场景持续性能|**未验证**，已请求coordinator安排；headless不替代|
|相关与全量回归|相关5套运行器rc0，串行重查后marker+rc计5/5，但严格forbidden审计仅connectivity干净，另4套含解析/泄漏禁用输出，不计全绿；全量未验证|
|独立复核代理|已多次向coordinator请求，子会话无Agent启动工具；结果未收到，未验证|

主原始证据：`G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/probe.json`、`match.log`、`dotnet-build.log`、`editor-parse.log`。

## 失败与环境风险（全部保留）

1. failed-first-probe：工具fast_state未带as_player，合法拒绝；修工具后重跑。
2. failed-second-probe：工具误期待顶层match_id，实际协议ok/state；按真实协议修正判据，并非改产品行为/放松网络成功要求。
3. failed-third-port-exhaustion：Windows发送前connect WinError10048；加180s仅发送前退避，不重放已发送命令、不关闭TIME_WAIT、不改全局OS参数。
4. failed-fourth-augment-pause：该轮10000已经全成功，随后300行时正常90s草案暂停+缓存污染导致overlay card_style错误，无人选择导致超时。夹具PROCESS_MODE_ALWAYS合法pick offer，再完整重跑第五轮rc0。
5. 当前global script class cache把ProductionTheme指向旧`res://agent/runs/healthbar/with-change/ProductionTheme.gd`，日志hides global class/依赖compile error；headless Minimap null texture/Nav inactive错误，完整日志127条ERROR。没有修改这些无关源代码或把错误过滤成绿；任务硬门未全过。
6. 工作区大量并行/既有修改，report/hash限DCS及任务专用tools；dotnet曾在第五probe接近结束时执行，不能用该轮FPS作为严格无干扰可见性能数字。

相关回归命令：`python G:/AIRTS/AI_RTS/tools/run_parallel_suites.py --godot G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe --ids adjutant-command-protocol,adjutant-connectivity,adjutant-observation,adjutant-rules-export,adjutant-ui-state-consistency --jobs 2 --out G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/related-regression`，运行器rc0；并行command rc1、observation超时rc-9，串行重查marker+rc变绿，但同样仍含禁用输出。严格清单 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/related-regression/strict-forbidden-audit.json`；不可把运行器5/5当严格闭环通过。

## RSI决策与完整未验证项

候选局部生命周期/协议回放已通过，但**不晋级全项目champion，needs-review**：未完成可见同场景持续A/B、截图实际打开、UI级玩家点选/框选接管录像、真实runner探索决策、网络大厅退局/第二局、连接128饱和和不读响应write压力、截图可见capture成功/全序、持续模拟秒/墙钟秒精确对照、相关回归最终判定、全量回归和独立代理复核，另有共享cache/无头渲染错误。连续champion未提升1产品候选轮；工具失败不当产品候选收益轮。计划与checklist继续维护，不以报告存在冒称完成。

## 附录：独占验证阶段边界闸门（2026-10-11 17:49）

状态更新：**blocked：当前候选发现合法完整行+FIN丢回执；暂停可见性能和全量，待最小产品补丁后重新跑门禁。** 本附录保留以上原始报告，不把旧10000成功推广为全部协议成功。

### 缓存污染精确处置

只修 `G:/AIRTS/AI_RTS/.godot/global_script_class_cache.cfg` 中两条已观察路径：ProductionTheme、ProductionCatalog 从 `res://agent/runs/healthbar/with-change/*.gd` 指向对应 `res://source/match/hud/production/*.gd`。核对source/tools/tests/project.godot没有引用该副本后，仅在已定位的副本目录加 `.gdignore`；副本4文件原样保留，未扫旧runs/未删除目录/未改产品。映射与文件SHA256证据 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/cache-repair.json`。新真实Match日志SCRIPT ERROR=0，ProductionTheme引用错误消失；仍有55条行首ERROR，不宣称工程日志全绿。

### 独立review风险的真实Match补测

命令 `python G:/AIRTS/AI_RTS/tools/dev/debug_tcp_boundary_probe.py` 工具rc0仅表示完成采集，**不是产品门禁通过**。正常Match/PlainAndSimple/2实体；launcher28116，真实PID30988；自然退出rc0。外部有限socket/退出watchdog保留，仅本轮PID所有权。CIM精确核验28116/30988/27792均无存活记录。原始证据 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/boundary-review/result.json`、`match.log`。

|边界|实测结果|判定|
|---|---|---|
|128 idle连接占位|129th status在2s截止超时；释放1peer后新请求恢复|已实测准入阻塞，不当作所有合法请求最终可用|
|1完整行+shutdown(SHUT_WR)|1/1响应|仅单行通过|
|300完整行+shutdown(SHUT_WR)，保留读端|仅1/300响应，随后EOF|**硬失败：明确丢合法完整行回执，需产品修复**|
|慢读/不读响应|SO_RCVBUF1024；提交20000 full status共320000字节，不读；旁路perf连续5次均约2s超时|可用性硬风险；尚未独立证明全部主线程停滞，不能把旁路超时直接称永久死锁|
|关闭慢读peer|perf恢复，clients/buffers=1/1；自然quit rc0|可恢复，但不豁免响应阻塞|

### 可见工具资格与剩余门禁

现有Instance仅CREATE_NO_WINDOW、video_smoke先launch再后台移窗，不能保证启动非激活。采用隔离Windows desktop启动，不切换用户desktop、不发送OS输入、不激活用户窗口。首轮GPU真实Match成功，但WindowCapture的EnumWindows失败，未取得截图/录像/帧时间，已自然quit并核验PID27792消失。工具失败证据 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/remaining-gates/result.json`。已将工具枚举改为EnumDesktopWindows，**尚未重跑**；独立desktop也不能冒称用户desktop后台可见UI通过。

专用夹具仅新增原始帧间墙钟样本、physics frame/time_scale/画质与相机记录接口；新隐藏Match加载无脚本错误。这是测量工具，不改变共享DCS。未跑同场景A/B，未生成可见截图并打开，未完成低频视频及回看，未测试截图混合pipeline全序或UI级输入。现配置全量实际124套，因FIN硬失败按协调指令未启动，未降低forbidden判据。独立静态review已交付 `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-11-debug-tcp-independent-review.md`，不替代独立运行时签署。

Requirement补充：缓存污染处置已完成且留证；128/FIN/慢读已执行但有硬失败；可见持续性能/截图实际打开/录像回看/UI-player/串行124套与严格审计仍blocked待补丁。当前候选不晋级champion，未新增产品候选轮，连续未提升仍1。用户PID、OS输入、打包版与无关产品均未操作。

## round-02 增量（18:08，待独立复核/串行剩余门禁）

首802e58候选因已证实FIN/慢读拒绝；没有reset共享树。新Controller方向将生命周期与输出义务排空绑定。候选SHA256 **32ce7607e0a4278fb72607b9fe53f94e7e9428e9d2ed99209a85a4f1bdeadfb4**，详细方向/精确不变量与实现依据见 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-02/direction.md`、`patch.md`、`verification.md`；基线/候选源码及完整共享diff都保存。唯一产品编辑DCS，原并行差异保留。

实际4.7.1官方stream_peer_socket.cpp确认poll在FIN可读且available=0时直接关闭socket；NONE不能恢复半关闭写端。新逻辑在已接收完整行/输出/截图义务未排空且无内核输入时不调用破坏性poll，精确partial read available，排空后poll及时回收；发送错误直接回收，不误认为FIN。所有响应改put_partial_data非阻塞，保留4byte LE UTF8长度+newline正文；每peer64KiB/全局1MiB写预算，高水位peer256KiB/全局16MiB暂停读/命令执行，不消耗合法排队行。单响应1MiB显式边界，大响应明确response too large，输出实际绝对界high-water+一条响应，约peer1.25MiB/全局17MiB。5s空闲仅无义务peer关闭并可计数，30s不完整行无进展截止，不用idle替代poll。截图保留异步超越语义，用现有path关联；每shot请求drawn更新后capture，headless5s无绘制显式错误。

|本轮门禁|实测结果|
|---|---|
|编译/解析|dotnet build rc0 0warning/error；autoload上下文headless quit-after1/no-adjutant rc0；新Match SCRIPT ERROR0|
|新PID真实Match10000完整短连接|10000/10000，77.281s；lifecycle/probe.json，launcher54116/actual21540，正常2实体|
|稳定性/维护|5after clients/buffers1/1；内存240.8→241.9MiB；64帧窗口p50 .03–.04 /p95 .27–.44 /p99 .49–.73ms，非整个stress分布|
|FIN300|300/300完整响应，无EOF丢失|
|128idle真占满/129th|独立fixture inspect clients/buffers128/128且idle_closed0后提交129th，4.969s自动恢复，不需主动关闭旧peer|
|20000full status不读|5旁路perf均完整成功0–16ms；关闭后恢复；输出水位不再阻塞主帧|
|截图混合FIN|unique path screenshot→status+SHUT_WR先status后5s显式no rendered frame，path关联一致；GPU成功capture和新鲜度仍未测|
|旧链路|UTF8半包/持续300/buffer与shot边界通过；scout位移15.244m；PlayerOverride组级；第二局不同match_id/2实体，自然退出rc0|
|清理/身份|新鲜mtime/sourceSHA验证identity.json；CIM精确查询所有记录本轮PID无残留；不碰用户PID/输入|

最终边界证据 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-02/boundary-capacity-refreshed/result.json`，驱动rc0且passed=true（不同于旧工具仅采集rc0）。早期boundary/verified虽FIN/慢读成功，未独立观察128满不能签容量；boundary-capacity首次工具timeout留证，建立128本身耗时超过5s，95peer已idle退出，只剩33。修工具在建立期间发合法status刷新activity，停止活动后观察真128再重放；没有改产品/放松129th判据。

状态 **needs-review，不晋级champion；连续未提升产品轮2**。目标新边界+万次已通过，已通知协调者安排独立review和串行剩余门禁。最终boundary55 ERROR/lifecycle111 ERROR行（两局）均SCRIPT ERROR0，但既有无头/退出错误仍在，严格日志非全绿。可见持续同负载A/B、GPU成功截图实际打开/新鲜度、UI/runner/大厅级、相关与124全量严格forbidden和独立签署仍待验证。旧失败原始记录完整保留，不以本轮局部成功宣称全部完成。


## round-03 全局背压不变量（18:31）

独立round02 review R2-01控制流反例确认：全局输出饱和暂停kernel读取时，空应用buffer不等于真正idle。Controller换方向而非盲加例外；唯一DCS编辑精确修复idle/incomplete仅kernel available==0截止，可读未收期间刷新activity。poll/FIN排空与128真正空闲5s政策均保持。>1MiB回应执行后替换错误新增execution_status=unknown/retryable=false及不得仅因该错误重放的detail；接口有1MiB正文限制，不保证动作未执行，不能盲重放非幂等命令，未证明所有大局回应低于此界。没有广泛协议重构。

冻结候选SHA256 **65795566d1ebf1e309ed02f7fddc45c743d54508738693cb826ceb8da9b60b47**。源码基线/候选/diff、Controller和Verifier见 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/`；独立review报告未修改，原共享差异保留。

- 编译与autoload解析rc0，0warning/error，新成功真实Match无SCRIPT ERROR。
- **全局实测** `round-03/global-03/result.json`：80slow peer各3000full status，真实应用输出16779384bytes饱和保持7.125秒；额外合法status+FIN每秒观测kernel28/input0/output0持续保留超过5秒。随后实际读取240000/240000原响应，额外status match=true，最终clients0/output0，自然rc0。不是单slow，不注入假队列，不降低水位。
- **新PID万次** `round-03/lifecycle/probe.json`：10000/10000，78.212秒，5after clients/buffers1/1；内存240.8→242.0MiB；64帧维护p50 .02/p95 .21–.27/p99 .36–.53ms，非整段性能分位。scout实际15.244m、PlayerOverride、第二局不同match_id/2实体，自然rc0；持续300/UTF8半包/异常重连/输入与shot限制全重跑。
- **全部旧边界** `round-03/boundary-02/result.json`：真128/128后129th4.968秒恢复，FIN300/300、20000status不读旁路5次0–16ms、mixed截图path关联/异步超越与FIN排空通过；GPU成功新鲜度仍待测。
- 精确CIM核验本轮11已记录launcher/actualPID均无记录；失败首启动watchdog仅清理拥有launcher。source hash/mtime及PID列表见identity.json。

失败证据完整保留：global首轮fixture Variant id推导导致解析失败，修工具int；global-02达到全局饱和后inspect文件写竞争JSONDecodeError；boundary首轮同类写竞争。只修工具有界等JSON完成，未再改产品/放宽断言；成功全部重跑。成功global/lifecycle/boundary日志仍136/130/58 ERROR行、SCRIPT ERROR0，不宣称严格全绿。

**状态needs-review，champion不晋级，连续未提升3产品轮，触发阶段饱和，停止继续微调。** 本轮请求的全局>5s+万次+既有边界/副官/第二局目标已通过，冻结hash交主代理独立判定；不启动可见/全量（后续代理独占），严格相关/全量、独立运行签署、GPU截图/可见A/B、UI/runner/大厅级仍未验证。

## 冻结round-03剩余门禁最终附录（20:43，保留所有前轮）

**最终状态needs-review，不晋级champion，连续未提升3轮不变。产品没有再修改。** 最终DCS SHA256仍为 `65795566d1ebf1e309ed02f7fddc45c743d54508738693cb826ceb8da9b60b47`，mtime epoch1791713815.7568915；每套启动前校验该hash，最后再次一致。严格最终证据 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/final-strict-audit.json` 包含124项逐套rc/marker/forbidden/错误行/功能失败行/log SHA256及mtime，核心round03原证据hash和PID审计。

### 可见非干扰资格：真实环境blocked

命令 `D:/software/anaconda3/python.exe G:/AIRTS/AI_RTS/tools/dev/debug_tcp_remaining_gates.py` 两次rc1。隔离Windows desktop启动源码Godot，Vulkan Forward+ / NVIDIA RTX3080Ti、正常Match2实体已运行，但EnumDesktopWindows未发现可捕获目标可见HWND；第二次修正64位API签名后仍失败。两次记录 `round-03/visible-01/result.json`、`visible-02/result.json` 与各visible.log，拥有PID29140/54892自然quit。没有切换用户desktop、系统输入、抢前台或操作用户PID；没有为了完成测试普通launch抢焦点。

因此**同负载/视角/画质持续GPU帧时间与模拟速度、截图实际打开、低频录像与实际回看、成功GPU截图新鲜度、UI-player仍blocked/未测**，没有生成可声称看过的PNG/视频。headless维护分位与历史46实体用户局不能冒称可见A/B。不继续无效工具微调。

### 串行完整124套与严格审计

命令 `python G:/AIRTS/AI_RTS/tools/dev/debug_tcp_serial_regression.py`。串行完成**124/124**，最终驱动rc1；严格原配置判据 `rc0 + 非空expected_marker出现 + forbidden为空 + 未超时` 为 **38/124**，marker+rc仅 **78/124**，不可替代严格通过。rc分布：0共79、1共35、watchdog超时-9共10；其中1项rc0但marker未通过。两次外部中断driver rc137，分别从持久化42/120续跑，不重复已完成项、不覆盖旧日志；最终四项完成，整个墙钟约125.3分钟。原timeout_seconds+240秒合同、CREATE_NO_WINDOW、显式--path源码、仅拥有launcher watchdog清理保持。

日志目录 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/full-serial/`；results.json为完整124项。最终审计重新读全部日志按原forbidden patterns判定，未改断言、marker或禁止模式，全部86项非绿明细在final-strict-audit.json。

分类（可重叠，不称所有红项无关）：
- 10超时：air-entity-move、control-groups、death-cleanup、entity-force-move、local-avoidance、multi-unit-command、navigation-stability、new-units-lineup、match-history、match-end-navigation。多数含null实例脚本错误；match-history解析无法resolve tools/probe_match_history.gd；new-units-lineup无forbidden但未完成。
- SCRIPT/Parse/load明确问题还包含background-music(Dictionary peace)、reach-geometry/null get_node、client-hp-first-sync/null RegisterProducer、unit-radius-coverage/null get_node；unit-grounding及generated-path-monitor缺生成地图资源（16-0、47-0）。rc0并不能豁免脚本错误。
- 35项rc1产品/断言不通过，包含balance-config-runtime、building-occlusion-fade、economy-account、helicopter-command、infantry-anim-driver/queue、legacy-hud、narrow-passage、match-outcome、movement-recovery、net-infantry、projectile-lifecycle、rule-ai-economy-query/expansion、placement类、tank命令/攻击类、worker-gather、world-query、apc-stability、voice/governor、ground-arrival、audio-settings、heavy-tank-howitzer、muzzle、ore-refinery、fog-range、size/spawn回归、movement-push-equivalence；每项实际失败文本保存在审计，不为得到绿色修无关产品。
- 多套marker+rc成功仍RID/ObjectDB/resources退出泄漏，严格失败。当前日志能定位现象，未执行旧DCS隔离反事实对照，不能断言全部既有或全部由DCS引入。

最后四套：spawn-point-regression rc1/forbidden泄漏、shape-pipeline rc0严格pass、strategic-chat-service rc0严格pass、movement-push-equivalence rc1。运行前观察非拥有43400 SpawnPointRegression及30596/38128 ra3-shared-nav实例，未结束它们；最后四套明确并发环境污染，仅功能证据，不据时延下性能结论，不能称全程完全隔离。

### Prompt逐条最终映射与未测范围

|任务要求|最终证据/判定|
|---|---|
|规则/报告/measurement/temporal/独立review|已读工程合同及上述规则，独立报告截至round02静态范围；round03独立运行签署仍未验证|
|poll线性生命周期、最小补丁、保留权限/画质/共享差异|主实现round03冻结DCS及direction/patch/verification；本验证阶段不改产品，不重写寻路/降画质|
|缓存污染精确处置、旧证据保留|cache-repair.json、两条source缓存路径及定位副本.gdignore，4文件未删，不扫旧runs|
|编译/解析/10000真实Match、稳态clients/buffers/内存/维护耗时|round-03/lifecycle/probe.json：10000/10000、1/1、240.8→242.0MiB、64帧p95 .21–.27ms；build/parse主实现rc0，非全窗口GPU分位|
|持续/半包/多行/FIN/异常断开/饱和/慢读|round-03/boundary-02/result.json及global-03/result.json；FIN300、128容量、80slow全局16.78MB>7s与240000排空已过，有限测试形态不推广所有协议上界|
|副官探索移动/选中接管/第二局|lifecycle/probe.json固定合法scout实际15.244m/PlayerOverride/第二match_id；command-level通过，收费runner决策/UI点选框选/大厅联网退出未测|
|同负载画质视角持续可见性能、截图打开、后台视频回看|visible-01/02环境blocked；未得图/视频/帧时间，不能以headless替代|
|截图返回/混合顺序|boundary-02支持headless显式错误/path关联与异步超越；不保证同连接全序；GPU成功capture/请求后图像实际查看未测|
|串行全量/严格forbidden、不放宽|124/124完整执行、38严格通过、最终rc1，86非绿全部保留；完整审计与124log，最终四套并发风险明示|
|当前源码/hash/mtime/清理所有权|final-strict-audit.json；冻结hash一致，精确CIM查询全部记录拥有PID；同数字3个已被非Godot browser/node/webview新进程复用，不视为Godot残留，不终止其进程；未见记录拥有Godot存活。无实例登记(AIRTS_INSTANCE_DIR为空)|
|报告附录/计划/checklist/champion|本附录及相应追加；阶段饱和3轮，needs-review、不晋级|

结论：局部TCP压力/边界修复有真实Match证据，但全项目硬门禁非绿且可见验收blocked；不预报400FPS、不宣称完整闭环通过。完整残余为可见A/B/截图录像/UI、独立round03运行签署、真实runner/网络大厅级、最大合法回应≤1MiB证明以及86项全量非绿归因修复。

### 主协调者最终完成审计

重新读取任务原文及最终原始证据；当前DCS SHA256与冻结候选精确一致。独立复核报告 `agent/reports/closed-loop/2026-10-11-debug-tcp-independent-review.md` 已包含round-03最终冻结签署（不是仅截至round-02）：静态生命周期、partial-write预算/帧格式、kernel待收请求idle反例修复局部通过，但没有独立运行时复现。上表该行的round-02范围由此更正。

主协调者以Python独立读取final-strict-audit.json，核验124项ID唯一、逐项日志SHA256全部一致（0不匹配），重新计数严格38、rc0=79/rc1=35/timeout=-9共10。lifecycle/global/boundary成功JSON及两份visible失败JSON均存在且mtime晚于冻结源码；不是凭计划、报告存在或运行器rc0判定通过。审计命令rc0只表示证据校验成功，不改变产品门禁结论。

目标交付包括最小生命周期补丁、不吞合法请求的有界背压、每轮编译后新真实Match万次压力和协议/行为/第二局回放，以及相同负载视角画质持续可见复验与原始结果/计划/闭环报告。前述局部修复与回放已有证据；持续可见复验没有证据，严格回归非绿，因此任务整体仍未达成。连续3轮不晋级后停止产品微调；未以大范围修复其他模块、抢用户桌面或结束非拥有进程来绕过阻塞。
