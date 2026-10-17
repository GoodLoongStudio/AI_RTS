# 副官 TCP 解帧与回归端口修复闭环报告

日期：2026-10-11。run-id：`2026-10-11-dtcp-corrective`（证据根目录 `agent/runs/2026-10-11-dtcp-corrective/`）。
提示词：`agent/prompts/2026-10-11-debug-tcp-corrective-handoff.md`。计划：`agent/plans/2026-10-11-debug-tcp-corrective-plan.md`。

状态：**P0/P1/P1b/P2 局部交付完成；P3 未做（无性能候选，超出本轮改动影响面）；P4 最终全量结果见 §7。整体验收 needs-review。**

## 一、结论（分状态）

| 状态项 | 判定 | 依据 |
|---|---|---|
| 驱动端口 | **pass** | 双端口分离后 5/5+2/2 套 DCS/bridge 各自监听成功、PID 归属本轮，MCP error22 全线消失（round-03 三套必现） |
| 客户端解帧 | **pass（本轮核心交付）** | 真实 `_tcp_json` 旧实现 6 项断言失败 → 新实现分包回归 0 failure + 真实 Match × 真实 DCS 端到端 strict 绿 |
| 相关回归 | **4/7 严格绿（基线 2/5）** | ui-state-consistency 由夹具补丁翻绿；observation 由端口修正翻绿；新套件 tcp-framing/real-dcs 一绿一已修复 |
| 可见长局性能 | **未验证（非本轮范围）** | 本轮未改 DCS/性能路径（客户端解析为秒级查询路径），无性能候选故无 A/B；遗留缺口同 summary 报告 §六 |
| 全项目验收 | **needs-review**（全量未跑完 15/127，用户转手动验收） | 全量停跑记录见 §7.1；command/rules 的 TestAllUnits 退出泄漏为既有未归因项（本轮拿到对象名单） |

## 二、改动文件与范围

| 文件 | 改动 | 说明 |
|---|---|---|
| `tools/dev/debug_tcp_serial_regression.py` | **重写 v2**（旧版存档 `runs/.../driver-v1-archive/`，sha256 `784BBCA7…`） | 双端口分离、监听资格核验、`--ids/--out/--run-id/--resume`、有界 watchdog、身份校验、cleanup_ok |
| `source/ui/AdjutantButton.gd` | `_tcp_json` 重写（+3 常量，约 32 删 56 增） | 长度帧解析（P1 核心）。注意：该文件工作树 diff 共 451 行，其中含**其他会话的未提交改动**；本轮改动前记录文件 SHA256 `E28DBFE3…`、只精确替换 `_tcp_json` 段落，未触碰其余区域 |
| `tests/automated/AdjutantUIStateConsistencyTest.gd` | +7 行 | 裸 Node 夹具补丁（quit 前 `node.free()`） |
| `tests/automated/AdjutantTcpFramingTest.gd/.tscn` | 新增 | 真实方法分包回归（6 场景族，发送端记录片长/时序） |
| `tests/automated/AdjutantClientRealDcsTest.gd/.tscn` | 新增 | 真实客户端 × 真实 DCS × 真实 Match 端到端 |
| `config/full_regression_suite.json` | +2 套件登记 | `adjutant-tcp-framing`、`adjutant-client-real-dcs`（工作树中另有其他会话的未提交套件扩充，未触碰） |

**服务端保持冻结**：`source/net/DebugControlServer.gd` 全程 SHA256 = `65795566d1ebf1e309ed02f7fddc45c743d54508738693cb826ceb8da9b60b47`（每次套件运行前驱动重验；未改服务端，故未重跑 24 万压力——符合提示词 §5）。

## 三、P0：驱动双端口修复与五套基线

**v1 缺陷（已证实）**：同一临时端口既替换 `{free_port}`（DCS `--debugport`）又写 `GODOT_BRIDGE_PORT`（MCP）→ 同进程两个 TCPServer 抢同一地址，DCS 成功后 MCP 必 error 22（归因报告 §3）。

**v2 修复**：
1. 端口：`config/dev_ports.json` `dynamic_dev` 段实测空闲块（复用 `tools/dev/match_instance.py::allocate_ports`），DCS=base+1、bridge=base+3，断言不同；不声称原子预留，由启动后核验兜住竞态。
2. 资格核验：DCS/MCP 监听日志（`[DBGCTL] 调试控制端点已启动`/`McpInteractionServer: Listening`）+ `Get-NetTCPConnection` 监听 PID 祖先链归属本轮进程树；绑定失败/归属不符 → 环境失败换端口重启（≤2 次），绝不连其它实例。
3. 权限语义保持：带 `{free_port}` 套件用显式 DCS 口；不带 `--debugport` 的保持受限 24579（被占时仅对已确认纯静态套件注入 `--no-adjutant` 并标注，不关占用者）。
4. `--ids/--out/--run-id/--resume`：续跑要求 driver/源码/配置 hash 与清单完全一致；不自动续用 round-03 results.json。
5. watchdog = 套件 `timeout_seconds` + 30s 明示余量（去掉 v1 的 +240s）；超时按本轮拥有进程树 kill。
6. 判绿 = `rc0 + marker + 原 forbidden 空 + 无超时 + cleanup_ok + 监听资格 + 非环境失败`。

**五套基线（修端口后、未修产品，`p0-serial-baseline/`）**：

| 套件 | round-03（旧驱动） | P0 基线 | 说明 |
|---|---|---|---|
| command-protocol | fail（MCP 同口 22） | fail（同泄漏谱系） | MCP 碰撞消失后泄漏仍在 → 与端口无关 |
| connectivity | pass | **pass** | 一致 |
| observation | fail（4 ObjectDB/2 resources） | **pass** | 泄漏随 MCP 碰撞消失——端口修正的直接收益 |
| rules-export | fail（MCP 同口 22） | fail（同泄漏谱系） | 同 command |
| ui-state-consistency | fail（6 ObjectDB/1 resource） | fail（同谱系） | 裸 Node 夹具缺陷 → P2 补丁 |

环境失败 0/5；strict 2/5（基线）。
## 四、P1：客户端长度帧解帧（核心）

### 4.1 修复内容（`_tcp_json`，`source/ui/AdjutantButton.gd`）

协议合同保持：请求 `UTF-8 JSON + 换行`；回应 `4 字节小端 u32 正文长度 + 该长度 UTF-8 JSON`；长度含末尾换行、换行不是完成判据。

旧实现缺陷：raw 中发现任意 `0x0A` 即停止收包——与协议冲突（长度前缀本身可含 0x0A：266→`0A 01 00 00`，65546→`0A 00 01 00`），头/首片一到就提前退出且永不剥前缀 → JSON 解析失败。

新实现：
1. 先攒 4 字节 → `declared = decode_u32(0)`；完成判据仅 `raw.size() >= 4 + declared`；头/正文跨任意分片合法。
2. 长度范围检查：`declared <= 0 或 > AUTHORITY_RESPONSE_BODY_LIMIT(1MiB，含末尾换行，对齐服务端 TCP_RESPONSE_LIMIT)` → 显式失败释放连接，不无界分配。
3. 完整正文一次 UTF-8 解码 → JSON；保留"解析失败打原文+原始字节"的排查输出。
4. 不足 4 字节/不完整正文/EOF/RST/超时/非法长度/非法 JSON 均显式失败返回 `{}`；**不把截断帧回退为"可能是裸 JSON"**；`_query_status_in_flight` 守卫由外层 `_query_status` 无条件清理（GDScript await 无异常路径），`_tcp_json` 有界返回保证不会永久 in_flight。
5. 超时合同不变：连接 0.5s + 读取 1.0s，改用**单调墙钟** deadline（`Time.get_ticks_msec()`），不忙等、不因每收一字节延期、未放大时限。
6. `put_data`/`get_data` 返回错误检查；发送失败记为"请求状态未知"，不构成"命令未执行"证明，不自动重放（服务端 `execution_status=unknown/retryable=false` 语义未动）。
7. 一问一答不变；不改服务端截图异步排序与发送协议。

### 4.2 分包回归（真实方法，`AdjutantTcpFramingTest`）

本地 TCPServer 作可控发送端，调用**真实 `_tcp_json`**（非 mock、非 Python 接收器）；发送端记录每片长度/时间与总帧字节（`[SENT] chunks=N total_bytes=…`）。

| 场景 | 断言要点 | 旧实现 | 新实现 |
|---|---|---|---|
| ① 266 字节正文，4 字节头 `0A 01 00 00` 先到、正文延迟 0.3s | 0.15s 检查点仍在等待；返回原字典；耗时≥0.28s | **FAIL×3**（0.07s 提前返回） | PASS |
| ② 65546 字节正文，首片 65536/尾片 14（总帧 65550，头 `0A 00 01 00`） | 首片后未提前退出；字段/pad 长度一致 | **FAIL×4**（0.02s 退出） | PASS |
| ③ 头 4×1 字节切分 + 中文码点（"副"3 字节）中间切开 | 完整解码无替换字符；<1.0s | PASS（头值无 0A，旧实现侥幸） | PASS |
| ④ 64 / 1048570 / 1048576（上限）正文 | 帧总字节=4+declared；字段一致；<1.0s | PASS | PASS |
| ⑤ 零长度/超限声明 1048577/残缺头/残缺正文+断开/连接即断/完整帧非法 JSON | 有界返回且不成功 | PASS | PASS |
| ⑥ 超时（只发 2 字节）后下一次合法查询 | 超时实测 0.9–1.8s（1.0s 合同）；第二次成功；服务端恰收 2 请求（不自动重放） | PASS | PASS |

**旧版先失败/新版再通过**：`p1-framing/legacy-run-02.log`（rc=1，6 项 FAIL）→ `p1-framing/fixed-run-02.log`（rc=0，0 FAIL）。驱动路径复验 `p1p2-serial`（strict=True）。

**测试基建的两个实测坑（已修并记录在测试注释）**：
1. GDScript 4 协程 fire-and-forget 不能赋值取返回值（Parse Error）。
2. 发送端节奏必须低于客户端轮询读取速率（约 3.2MB/s @20ms），否则内核缓冲积压令 `put_data` 阻塞冻结主线程、客户端定时器永不触发（**死锁**）；48KB/20ms 约 2.4MB/s 为安全值且接近真实服务端速率（`TCP_WRITE_BUDGET` 64KiB/帧 约 3.8MB/s）。

### 4.3 真实 Match 复验（`AdjutantClientRealDcsTest`）

无头真实 Match（`tests/manual/TestPlayerVsAI.tscn`，2 实体小局）× 真实 DCS（`--debugport`）× 真实客户端方法，8/8 PASS（`p1b-real-dcs/run-10.log`、驱动 `p1b-realdcs-driver4` strict=True）：
- status（大响应，full_vision）27ms 返回、match=true、units 有真实单位；
- rules（大帧）返回；adjutant_leases ok=true；
- 旧功能轨迹：对己方可移动单位（Drone）`op=move` → **Accepted**。

**夹具关键点（实测踩坑，注释已记录）**：DCS 按 `tree.current_scene` 找对局（DebugControlServer.gd L428）且 current_scene 必须直接挂 root；`_ready` 期间 root busy → 必须 `add_child.call_deferred`；headless 无渲染相机时 status 需 `full_vision` 否则视野过滤清空 units；收尾走 SmokeTestExit 规范退出（裸 quit 会留 headless dummy 渲染器 RID 泄漏）。不用 TestAllUnits（其退出泄漏谱系见 §五）。

## 五、P2：夹具所有权补丁与剩余泄漏归因

### 5.1 UI 裸 Node 补丁（已交付，fail→pass）

`AdjutantUIStateConsistencyTest.gd` 创建 `AdjutantButtonScript.new()` 不挂树、不释放（归因报告确认的夹具缺陷）。补丁：quit 前 `node.free()`。

**verbose 对照（`ui-node-verbose/`）**：
- 修前（Python subprocess + verbose，复现路径）：`6 ObjectDB leaked`（**Node + GDScript + GDScriptNativeClass + 3×RegEx**——后三者为 `AdjutantButton.gd:152-154` 的 `_op_regex/_path_regex/_kv_regex` 实例成员）+ `1 resources still in use`——泄漏链条与归因报告假设**完全闭合**。
- 修后同路径：0 泄漏；驱动路径 `strict=True`（`ui-after-fix/`）。
- 附带发现：该套件的泄漏对**启动方式敏感**（PowerShell `Start-Process` 路径下 5/5 不报、Python subprocess/驱动路径下稳定复现）——补丁后两种路径均干净，不再依赖该敏感性。

### 5.2 command-protocol / rules-export 退出泄漏（既有未归因项，本轮拿到对象名单）

verbose 归因（`p2-attribution/cmdproto-verbose.log`，116 条泄漏实例）：**45×Node3D、18×AnimationPlayer、18×MeshInstance3D、10×GDScript、4×GDScriptNativeClass、3×Node、3×NavigationObstacle3D、3×Area3D、3×CollisionShape3D、2×ArrayMesh、1×CylinderShape3D**——全部为**表现/渲染类节点**，无任何 TCP/StreamPeer 类型；与归因报告 §4.5"不能用 RID/Nav/Area/renderer 泄漏反推 DCS 残留"一致，且数量与 round-03 的 115 ObjectDB 谱系吻合。

机制假设（部分归因，未逐对象证实）：与 `SmokeTestExit` 注释记录的 `add_child.call_deferred()` 生成节点（如 ResourceDecayAnimation 的 Node3D/GPUParticles3D）在整局 `queue_free` 后仍被挂接的时序问题吻合。**修复属 Match 拆除时序/夹具范畴，不属本轮 TCP 范围**（不改 DCS、不扩大任务），列为独立后续项。

### 5.3 端口修正对泄漏的影响（新证据）

observation 套的 4 ObjectDB/2 resources 泄漏随 MCP 碰撞消失而消失（§三表）——归因报告"端口错误不是 forbidden 直接匹配项"的表述需补充：**对 observation 而言，MCP error22 失败路径就是其退出泄漏的来源**。

## 六、P3：可见长局性能——不做（范围判断，非回避）

- 本轮改动面：驱动（测试工具）、`_tcp_json`（面板**秒级查询**路径，非每帧逻辑）、两个测试夹具。**不在帧时间关键路径上，无性能候选**，故无"修复前后 A/B"可言；按提示词 §6，无合格旧版对照时只可称"修复后稳定性复验"——而可见长局复验本身（46 实体、窗口帧时间、录像回看）是上一会话的**独立未完成项**（summary §六），不因本轮局部修复而自动获得。
- 未改 DCS（hash 冻结）→ 按提示词 §5 不重跑 24 万压力；DCS 的万次/背压证据维持 round-03 原样。
- 用户完整试玩由用户进行。**可见长局性能保持 `未验证`，不借历史数字推算。**

## 七、P4：最终全量（127 套）

环境说明：非独占时段（另有会话并行跑 headless 单套测试与用户面板 runner），驱动按本轮拥有 PID 树管理自己的实例，不操作他者。结果以 `final-full/results.json` 落盘为准。

### 7.1 最终全量结果

**按用户要求停止（未跑完）：已执行 15/127 套，落盘 `final-full-v21/results.json`（strict 6、env_fail 0）。**用户改为手动验收，本轮不再自动化续跑。

已跑 15 套明细：6 严格绿；9 非绿——其中 5 套为既有退出泄漏谱系（rc0+marker 但命中 RID/ObjectDB/resources：command-protocol、rules-export、combat-sfx、damaged-producer-speed、vehicle-factory-worker-production），3 套 rc=1（background-music、balance-config-runtime、building-occlusion-fade），1 套 watchdog 超时 rc=-9（air-entity-move，并行负载下的时间超限，非产品判定）。

**清理**：本轮拥有的全量进程树已按 PID 清理（驱动 16532 + conhost 34772/36124 + console 3124 + 游戏 3908），24579 已释放；未操作任何他者进程。

**未来续跑**：`python tools/dev/debug_tcp_serial_regression.py --run-id 20261011-dtcp-corrective-final-full-v21 --out agent/runs/2026-10-11-dtcp-corrective/final-full-v21 --resume`（身份 hash 校验防混合树；需 24579 受限口空闲）。首次尝试的中止记录保留在下面作过程证据。

- 全量于 22:58:20 启动（127 套，`final-full/`），完成第 1 套（adjutant-command-protocol，rc=0 strict=False 同既有泄漏谱系）后**中止**。
- 中止原因（两项，均已核实）：
  1. **驱动 v2 崩溃 bug**：受限口 24579 被占且套件未确认纯静态时，驱动三连 `continue` 后返回 `row=None` → `persist()` TypeError（`final-full-driver.err.log`）。已修复为生成规范的环境失败行（驱动 v2.1，py_compile rc=0）。
  2. **受限口被并行会话占用**：无 `--debugport` 的套件按产品语义监听 24579，而另一会话正连续跑测试（22:55 `OreRefinerySmokeTest` → 23:08 `SpawnPointRegression`，pid 58100 监听 24579 中）。127 套中约 120+ 套无 debugport，当前窗口无法隔离受限链路；按"不能扩大产品端口配置来凑绿"与"记录真实限制"，不强行跑出大量 env_fail 的无意义全量。
- **续跑方式**：驱动支持 `--resume`（身份 hash 校验防混合树）。待 24579 空闲窗口执行：`python tools/dev/debug_tcp_serial_regression.py --run-id 20261011-dtcp-corrective-final-full --out agent/runs/2026-10-11-dtcp-corrective/final-full --resume`。
- 已有全量级证据 = §三（五套基线，双端口修正后）+ §4/§5（ui-state 翻绿 + 2 新套件）+ `p1p2-serial/`（7 套 4 绿、0 环境失败）。

## 八、未验证项与限制

1. **可见长局性能/动态证据**：未做（§六）。
2. **command/rules 退出泄漏**：对象名单已取（§5.2），根因修复未做（超范围）；其与 GeneratedTerrain/MovementObstacle 退出栈的因果关系未验证。
3. **独立复核**：本报告由实施者自查（hash/日志/rc 全部落盘）；尚未有第二会话独立复跑——分状态 needs-review 的原因之一。
4. **受限运行链**：ui-state/connectivity/framing 在 24579 空闲时按原样（受限模式）跑过；"24579 被占→--no-adjutant"分支本轮未实际触发（24579 全程空闲），该分支代码路径未实测。
5. 新套件未在**其他会话环境**复跑；`adjutant-client-real-dcs` 依赖 TestPlayerVsAI 场景时序（units 等待 10s 预算）。
6. P1b 的 status 用 `full_vision` 取全量 units（headless 无相机）；生产面板路径（as_player 视野语义）未在本测试内复现，由面板既有连通/状态测试覆盖。

## 九、产物索引

- 基线：`agent/runs/2026-10-11-dtcp-corrective/p0-serial-baseline/`（results.json + 5 日志）
- 分包回归：`p1-framing/`（legacy-run-02.log 旧失败、fixed-run-01/02 新通过）
- 真实 Match：`p1b-real-dcs/`（run-09 调试明细、run-10 全绿）、`p1b-realdcs-driver4/`（驱动 strict 绿）
- UI 补丁对照：`ui-node-verbose/`（修前 verbose 复现/修后干净）、`ui-after-fix/`
- 归因：`p2-attribution/cmdproto-verbose.log`（116 泄漏对象名单）
- 7 套：`p1p2-serial/`；最终全量：`final-full/`
- 旧驱动存档：`driver-v1-archive/`
