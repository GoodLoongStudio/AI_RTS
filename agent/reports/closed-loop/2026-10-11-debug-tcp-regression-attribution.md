# 最终 DCS 相关回归归因：只读分析

日期：2026-10-11。状态：**needs-review；端口工具错误已证实，退出泄漏仅部分所有权缺陷可证实，泄漏总量未完成运行归因。**

## 1. 范围、身份与证据

本轮只读取规则、prompt、主闭环报告、独立review、最终strict audit、五套原始日志、测试与专用fixture及相关产品代码；唯一新增文件是本报告。未改产品、测试、缓存、主报告；未启动Godot、编译、网络探测、性能负载或Windows端口状态查询，不操作任何运行实例。GPU由 `agent_cf9f223c-707c-43f0-8e9c-648c1faeef41` 独占；本报告不消费其尚未交付的结果。

开发根 `G:/AIRTS/AI_RTS`；Git根检查rc0，报告目标 `check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-11-debug-tcp-regression-attribution.md` rc0。工作区存在大量并行差异，保留原样。文档分析按RSI文档例外不运行真实Match；此例外不豁免原产品任务的门禁。

已核验当前 `G:/AIRTS/AI_RTS/source/net/DebugControlServer.gd` SHA256：
`65795566d1ebf1e309ed02f7fddc45c743d54508738693cb826ceb8da9b60b47`，mtime epoch `1791713815.7568915`，与最终冻结对象一致。

证据入口：
- prompt：`G:/AIRTS/AI_RTS/agent/prompts/2026-10-11-debug-tcp-lifecycle-fix.md`
- 主报告（未修改）：`G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-11-debug-tcp-lifecycle-fix.md`
- 最终独立静态review（未修改）：`G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-11-debug-tcp-independent-review.md`
- 审计：`G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/final-strict-audit.json`
- 五套原日志与实际启动命令：`G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/full-serial/` 的对应 `.log`、`results.json`。

本轮重新读五份原日志并核验SHA256，**5/5与审计一致**，不是只相信摘要。最终全量38/124严格绿、86非绿仅作为门禁背景；本报告不重审124、不把86泛化为既有或无关。

## 2. 五套最终结果：不是早期解析污染那轮

五套均rc0、成功marker存在；只有connectivity严格绿。最终五份日志**SCRIPT ERROR均0**；不能把早期related-regression的ProductionTheme解析污染套用到这些最终日志。

|ID|strict|行首ERROR数量|退出泄漏|启动端口|
|---|---|---:|---|---|
|adjutant-command-protocol|fail|677|115 ObjectDB / 17 resources；多类RID|DCS61675成功；MCP同61675失败22|
|adjutant-connectivity|pass|0|无|DCS24579；MCP61471成功|
|adjutant-observation|fail|889|4 ObjectDB / 2 resources；无RID泄漏命中|DCS65121成功；MCP同65121失败22|
|adjutant-rules-export|fail|677|115 ObjectDB / 17 resources；多类RID|DCS52320成功；MCP同52320失败22|
|adjutant-ui-state-consistency|fail|1|6 ObjectDB / 1 resource|DCS24579；MCP65155成功|

原日志文件名分别为 `adjutant-command-protocol.log`、`adjutant-connectivity.log`、`adjutant-observation.log`、`adjutant-rules-export.log`、`adjutant-ui-state-consistency.log`，均在上述绝对目录。

`G:/AIRTS/AI_RTS/config/full_regression_suite.json:4–16` 原forbidden包含RID/ObjectDB/resources泄漏、SCRIPT/Parse/load/assertion等，**没有泛化的所有ERROR禁则**。因此listen22本身不是这三套strict=false的匹配原因；它仍是真实工具错误，不能因不匹配forbidden就忽略。677/889条ERROR也不等于677/889项断言失败。

## 3. listen error22：可证实的双服务同端口分配错误

确定链路：
1. `G:/AIRTS/AI_RTS/tools/dev/debug_tcp_serial_regression.py:20–22` 用Python `bind(('127.0.0.1',0))` 取得一个port并关闭探测socket；同一个port同时替换测试的 `{free_port}`（`--debugport`）与环境 `GODOT_BRIDGE_PORT`。
2. `G:/AIRTS/AI_RTS/project.godot` autoload顺序为DCS在29行、McpInteractionServer在45行。
3. `G:/AIRTS/AI_RTS/source/net/DebugControlServer.gd:169–194` 将 `--debugport` 对应port绑定 `127.0.0.1`；三份日志已先输出DCS监听成功。
4. `G:/AIRTS/AI_RTS/autoload/mcp_interaction_server.gd:29–38` 从 `GODOT_BRIDGE_PORT` 读同一port，调用另一个TCPServer.listen；三份日志随即报告相同port失败22，栈定位其38行。

**结论：专用串行driver把两个独立监听服务分配到同一地址/端口，属于可证实工具错误。** 数值61675、65121、52320全部在合法端口范围；不是超过65535/负数。日志返回的是Godot `Error` 编号，不是直接记录的Windows WinError或POSIX errno，不能把22机械解释成EINVAL/“端口不合法”。

Windows excluded range、端口释放后被其他进程抢占是一般待排查条件，但**不是这三次错误的必需解释**：同一进程DCS已经成功监听相同port，这是更强直接证据。当前没有当时的netsh/TCP快照，不能声称排除所有Windows因素；也不能把excluded range当已证实根因。Python临时bind成功仅证明其当时可bind，不能消除TOCTOU。

connectivity/UI没有 `--debugport`，DCS用24579，MCP用另一个随机port，因此不触发本driver的确定性碰撞。它们仍可能遇到默认24579被其他实例占用，此次原日志未发生。

对比专用压力工具：`G:/AIRTS/AI_RTS/tools/dev/debug_tcp_lifecycle_probe.py:31–38` 分别取DCS与bridge port，避免了确定性复用，但两次先关闭socket再启动，仍未显式断言port不同/消除竞态；不能将其视为严格原子预留机制。

## 4. load → exit与泄漏：证实缺陷和未归因分开

### 4.1 UI套：可证实的夹具孤儿Node，不是TCP连接累积证据

`G:/AIRTS/AI_RTS/tests/automated/AdjutantUIStateConsistencyTest.gd:36` 创建 `AdjutantButtonScript.new()`，不 `add_child`、不 `free/queue_free`，98–103行直接quit。Node不是RefCounted；局部变量离开作用域不等于释放其原生实例，且没有父节点负责递归释放。

这是**确定的测试所有权缺陷**，至少提供一个未释放Node的直接来源；其 `_ready` 不运行，所以不是实际按钮/HTTPRequest安装或runner运行测试。对照connectivity只调static函数、不创建该Node，最终日志干净，支持优先检验此假设。

但原日志没有 `--verbose` 的实例类型/资源路径，**不能把6 ObjectDB+1resource全部算到该Node**。全项目autoload、菜单音频、脚本资源或C#终结时序仍可能贡献其他对象。此处结论是“夹具确定漏free”，不是“总泄漏已经完整归因”。

### 4.2 command/rules：不是简单没释放Match

- `G:/AIRTS/AI_RTS/tests/automated/AdjutantCommandProtocolSmokeTest.gd:27–28` instantiate并挂载 `TestAllUnits.tscn`；177行传 `_match` 给 `SmokeTestExit.request`。
- `G:/AIRTS/AI_RTS/tests/automated/AdjutantRulesExportSmokeTest.gd:16–19` 挂同场景；214–223行新建观测Node并**add_child**到测试根；209–211行先queue_free Match、等一帧，再调用退出工具。
- `G:/AIRTS/AI_RTS/tests/automated/SmokeTestExit.gd:17–23` 传根时queue_free并等两process_frame；未传根时不额外回收Match；两分支都静音全树音频、stream置null，0.1秒timer后quit。

因此command已经使用规范的整局回收，rules也有显式回收；不能只读“泄漏”就说两套完全没释放整局。两套同115/17和同RID谱是**共享TestAllUnits/load/exit路径候选证据**，不证明具体泄漏对象相同，更不证明旧版DCS也如此。

### 4.3 observation：不同夹具，较少剩余对象，仍未定位类型

`G:/AIRTS/AI_RTS/tests/automated/AdjutantObservationSmokeTest.gd:23–27` 挂 `TestPlayerVsAI.tscn` 并固定等待0.7秒；126–128行queue_free Match、等一帧，再退出工具。异常检查35–38、101–103行失败会直接return而不触发退出，是潜在夹具watchdog风险，但**本次0failure最终marker已到达，不是该失败路径**。

剩余4 ObjectDB/2resource没有verbose明细，不能确定是音乐、C#集合、脚本常量或其他引用；不能直接归因DCS客户端。

### 4.4 已定位的真实产品load/exit错误栈，不等于泄漏根因

三套真实Match日志均见：
- `Minimap.gd:199 live_tex.get_image()` → dummy rendering `texture_2d_get` 参数t为null，属于headless渲染读取路径；不是DCS TCP发送。
- 退出后 `MovementObstacle.gd:269 _clear_logic_blocker` → 299 `clear_structure_blocker` → GeneratedTerrain重建占位/采样 → `sample_world_height:593/595` 的global_transform在已离树地图上访问。产品退出路径有明确栈证据，不能全部叫夹具红或只因延期退出就豁免。
- command/rules还见 `GeneratedTerrain.gd:1109 geo.get_path()` 离树错误；nav `map_index < 0`。其与RID泄漏是否因果相连仍未验证，禁止只凭错误相邻就断言根因。

`TestAllUnits.tscn`、`TestPlayerVsAI.tscn` 均继承正常 `Match.tscn` 并使用 `G:/AIRTS/AI_RTS/tests/manual/Match.gd`（super正常Match，部分测试禁终局面板）；地图是Match子节点，不是fixture在外部遗忘的独立地图。

### 4.5 DCS引用链与专用fixture边界

`G:/AIRTS/AI_RTS/source/net/DebugControlServer.gd`：
- `_adjutant_observation` 在206–210行创建并add_child到DCS；正常树释放会递归回收，不是裸Node遗忘。
- TCP `_clients`、`_pending_shots[*].client`、短暂 `_current_client` 持有peer引用； `_buffers/_outputs/_last_activity/_close_after_flush` 用instance ID键；358–365行drop清字典并disconnect，幸存数组替换与shot prune另负责去引用。无显式DCS `_exit_tree` 清TCP/shot，退出时尚有义务的peer仍需独立覆盖。
- 三个Match smoke主要直接调op，UI两套无TCP发送；日志没有提供peer数量/对象类型证明。不能用其RID/Nav/Area/renderer泄漏反推“DCS残留了115个TCP对象”。
- C# `G:/AIRTS/AI_RTS/source/csharp/GodotAdapter/Adjutant/AdjutantObservationRuntime.cs` 只有快照计数持久字段；Match作为方法参数使用，未看到长期Match字段。DCS规则/情报字典等跨局缓存存在，但当前静态证据不足以证明它们持有这些泄漏Node/RID。

专用 `G:/AIRTS/AI_RTS/tools/dev/debug_tcp_match_fixture.gd` 使用正常 `Match.tscn`、MatchSettings/PlayerSettings与PlainAndSimple，40行map setter会add_child归属Match，41–42行挂root且设current_scene；重开106–111行先清current_scene、queue_free、等两帧再创建；退出103行传Match给SmokeTestExit。它通过TCP/file控制及selected_units组注入，不走大厅按钮/真人点选。**该fixture能验证其拆局/重开形态，不能替代五套自身退出代码或联网大厅路径。** 当前quit不先清current_scene、成员不置null可作为对照变量，但成员持有Node不等于阻止显式queue_free，不能据此宣称泄漏根因。

## 5. 后续最小独立复现（仅给方法/命令，本轮未执行）

必须等GPU独占代理交还运行时段；不与其headless/GPU同时开负载。先只跑一个UI套与一个command套的verbose，不重跑124、不覆盖round-03旧产物。新日志目录建议 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-attribution-independent/<unique-run>/`。运行前记录DCS/相关文件SHA/mtime，禁止混合树。

### A. 单套端口碰撞对照和verbose对象定位

以下PowerShell命令模板用于未来授权时段。`$dcs/$bridge` 应由调用方选两个**不同**、当时无监听且不在excluded范围的端口；示例数字仅示例，不保证可用。保持非激活隐藏控制台，30秒外部watchdog只清拥有PID树，保留stdout/stderr、真实Godot PID和rc。

```powershell
$root='G:/AIRTS/AI_RTS'
$godot='G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe'
# 只查询，不修改Windows范围或终止监听者；现在的快照不代表历史时刻。
netsh interface ipv4 show excludedportrange protocol=tcp
netsh interface ipv4 show dynamicport tcp
Get-NetTCPConnection -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess
$dcs=24631; $bridge=24632
if ($dcs -eq $bridge) { throw 'DCS and MCP ports must differ' }
$env:AIRTS_INSTANCE_DIR=''; $env:AIRTS_INSTANCE_STRICT_DCS='0'
$env:GODOT_BRIDGE_PORT=[string]$bridge
$out="$root/agent/runs/2026-10-11-debug-tcp-attribution-independent/"+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')
New-Item -ItemType Directory -Path $out | Out-Null
$scene='res://tests/automated/AdjutantCommandProtocolSmokeTest.tscn'
$args=@('--headless','--verbose','--path',$root,'--quit-after','200000',$scene,'--','--debugport',[string]$dcs)
$p=Start-Process -FilePath $godot -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput "$out/stdout.log" -RedirectStandardError "$out/stderr.log"
if (-not $p.WaitForExit(30000)) {
  taskkill /PID $p.Id /T /F  # 仅本轮拥有的launcher树；先记录实际子PID/命令行
  throw 'Owned single-suite watchdog timeout; preserve logs'
}
$p.Refresh(); $p.ExitCode
```

第一次严格不同port；第二次新目录同场景把bridge改成dcs重放原工具错误（只在自己的实例内，绝不选择用户端口）。预期前者两个listen成功，后者DCS成功而MCP22；若不同port也失败才继续记录Winsock/排除范围/占用证据。测试退出泄漏是否随MCP碰撞消失另行判定，不把listen归因自动延伸为泄漏归因。

UI最小原样verbose对照：把 `$scene` 换 `res://tests/automated/AdjutantUIStateConsistencyTest.tscn`，args去掉 `--debugport`，追加 `-- --no-adjutant` 可作DCS关闭反事实；再不带 `--no-adjutant` 单跑原样。原样启DCS使用24579，先查无其他监听，不碰已有实例。connectivity用同模式作static control。其余两个Match smoke同样只替换scene逐套运行。

### B. 泄漏归因的最小变量矩阵

未来经授权才建立**隔离测试fixture/worktree**，不编辑冻结产品和现有测试判据：
1. UI原样 vs 唯一变化在测试完成后对裸 `node.free()`；均verbose。比较泄漏实例class/script/path，剩余5对象若仍在则继续定位，不能宣布全绿。
2. command原样verbose优先，确认115对象名单、孤儿节点路径与RID；该套已经传Match根，不能重复“加传根”当修复。
3. rules/observation隔离fixture统一改成 `SmokeTestExit.request(tree, rc, match_instance)`、取消自身一帧预释放；只比cleanup变量，不改断言。观察退出采样错误及RID是否仍在。
4. 若名单指向音频，用只停止音频/stream清空的对照；若指向Nav/Area/renderer，记录残留Node、RID所有权及queue_free前后两帧/0.1秒计数。延期退出消失只能证明清理时序敏感，不直接证明产品无缺陷。
5. DCS特异性用授权登记的隔离worktree对冻结版与前候选同fixture/同种子/同退出轨迹比较，或无TCP义务 vs 留活peer/待截图退出。关DCS会使command/observation依赖失效，不应拿 `--no-adjutant` 破坏它们再比较失败总量；rules可保留自己挂的观测Node做无DCS对照。

禁止直接执行现有 `debug_tcp_serial_regression.py` 作最小复现：它恢复已完成124结果、硬编码旧输出目录且复用端口；不能产出新的独立五套证据。现有lifecycle也写旧目录、boundary/global `exist_ok=False` 会因目录存在失败。未来若复用只能在内存导入后指定全新 `OUT` 再main，并先查模块行为/端口分配，不直接覆盖核心JSON；10k/global压力不是本轮泄漏定位首选。

判定合同保持 `rc0 + 正确marker + 原forbidden为空 + 无timeout`；verbose定位不能删除错误行或改forbidden。本报告没有实现或运行上述变体，没有新的独立runtime rc/截图。

## 6. 哪些仍缺：区分prompt显式目标、仓库硬门与拓展证明

### Prompt显式要求

- 每轮真实无头Match至少10000完整短连接、clients/buffers稳态、成功率/内存/维护耗时：最终主线有证据；本轮不重复。持续/半包/多行/异常断开重连亦有主线证据。
- 保留协议/权限/副官语义、不吞合法请求、合理上限/背压：局部静态与FIN/全局压力有证据；受限模式运行正反、所有合法大回应≤1MiB及长期满容量可用性尚未证明，不能推广为任意请求完整兼容。
- 副官探索移动、玩家选中接管、退出第二局：固定scout位移/selected_units组/fixture拆局重开有证据，正常UI选中接管链仍未测；prompt未明确要求收费模型runner实际决策或联网大厅按钮，后两者是更强端到端范围，不应伪称prompt逐字强制。
- **相同负载/视角/画质持续可见复验、实际帧时间**：旧visible-01/02 blocked；新GPU代理正在验证，不提前认定通过。万次headless维护64帧分位不是此项。
- 原始结果、计划/闭环记录及共享改动保护：已有记录；本轮不改主报告。不预报400FPS、不用physics_script_ms冒充独占脚本时间。

### 仓库强制门禁仍缺

- 相关五套严格仅1/5；即使已证实端口工具错误，四套退出forbidden未清，不得签相关全绿。
- 全量已经执行但严格38/124，不能把“跑完”变成“门禁通过”。86非绿未完成逐因归属；本次不修无关source、不推广既有结论。
- 最终独立review已对冻结hash静态通过，**尚无独立运行时复现签署**；不能说独立复核仍只有round02，也不能说静态签署替代独立真实Match。
- 需要成功截图并实际打开；动态玩家UI需低频录像、动作时间线与实际回看（闭环/temporal规则），不是prompt逐字提到视频但仍属相关仓库验收规则。当前旧证据没有图/视频可看；等待GPU代理产物。
- 隐藏实例身份、新鲜hash/mtime、真实PID与退出清理继续要求；历史主线有清理审计，但此轮没有新的独立拥有实例，不能添runtime cleanup pass。

最终建议：先保留最终DCS冻结、不继续产品微调。待GPU时段结束，以不同双端口的单套verbose与UI裸Node释放对照进行最小独立归因；只在具体类型/引用/退出栈与反事实闭合后决定修夹具还是产品。**端口碰撞可证实为工具错误；UI裸Node漏free可证实为夹具缺陷；其他泄漏数量与最终DCS TCP引用的因果关系仍未归因。**
