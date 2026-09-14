# AI 副官 P0/P1/P2/P3 未完成清单（历史进度记录）

> 2026-09-14：本文件保留历史证据和当时状态，不再是新一轮升级的进度入口。后续按 [实战能力升级计划](AI副官_实战能力升级计划_2026-09-14.md) 和 [本轮执行进度](AI副官_实战能力升级执行进度_2026-09-14.md) 实施。下文“达标”“待用户批准”等是历史记录，不自动证明本轮通过，也不构成本轮停工要求；F1–F5 已在新进度中映射，须核对当前实现与真实结果。

创建：2026-09-13 ｜ 依据：`AI副官_高频扫描、多线并行与安全行军计划_2026-09-12.md` §10
纪律：**每次修改 / 测试 / 短局 / 阶段报告后更新本文件**；结束任何一轮回复前先重读本文件，
自动挑"下一条未完成项"继续做，**不许用阶段性报告代替完成**。
证据层级严格区分：代码推断 / 自动测试 / 场景启动 / 日志证据 / 截图证据 / **真实游戏结果** / 尚未验证。

---

## P0 快速链路和埋点

| 字段 | 内容 |
|---|---|
| 状态 | ✅ **达标**（扫描 9.14Hz / 协调 2.00Hz / 快照年龄 p50/p95/max = 53/106/132ms） |
| 对应代码 | `deploy/agent_runner.py`（`--full-view-interval` 视图缓存、固定节奏主循环、`coord_hz`/`observe_ms` 埋点）、`deploy/fast_scan.py`（失败重试）、`net/DebugControlServer.gd`（10Hz 采样缓存 + `arrival`/`path_failed` 采样） |
| 测试命令 | `python -m unittest adjutant_coordinator.tests.test_fast_scan` |
| 真实对局证据 | `state_p3_clean`：扫描 9.14Hz、协调 2.00Hz、单轮 p50 135ms、观测 p50 6~10ms、扫描错误 16（0.5%） |
| 剩余问题 | ① `task_deltas` 事件仍是"显式不支持"（权威端无独立任务节点可采样）；② 扫描 `non-json` 已从 4% 降到 0.5%，**未归零** |

## P1 多线调度和批量权威闭环

| 字段 | 内容 |
|---|---|
| 状态 | ✅ **达标**（四线 99%+ 轮次有任务、每轮同时活跃 4 条；**批量 21 批 / 51 条**；回执 121 接受 / 3 几何拒绝） |
| 对应代码 | `graph/lanes.py`（饿死判据改为"本轮候选>0 且超时未服务"）、`coordinator.py`（**批量根因修复**：`_transport`=对象、`_send_one`=单发方法）、`graph/runtime.py::_dispatch`、`deploy/agent_runner.py::AuthorityIntentTransport.send_batch` |
| 测试命令 | `python -m unittest adjutant_coordinator.tests.test_coordinator adjutant_coordinator.tests.test_lanes` |
| 真实对局证据 | `state_p3_clean`（批量计数取自 runner tick 日志 `batch.calls`）；饿死告警 13 次均匀分布四线 |
| 剩余问题 | ① 批量收益有限（每轮通常 1~2 条意图）；② 任务完成率仍有 `active_unknown`（**不把 Accepted 当 Completed**） |

## P2 安全移动

| 字段 | 内容 |
|---|---|
| 状态 | ✅ **达标**（无路径移动 0、未过闸门 0、越界全拦、遇敌停止 386 次拦截） |
| 对应代码 | `graph/movement.py`（闸门/中继点/威胁/小队/到达与路径失败闭环）、`graph/nodes.py::_gate_movement`+`_consume_fast_events`、`net/DebugControlServer.gd::_op_adjutant_nav_path`+`_fast_sample_movement` |
| 测试命令 | `python -m unittest adjutant_coordinator.tests.test_safe_movement`（30 条） |
| 真实对局证据 | `threat_ai`（威胁拦截 226、遇敌紧急 2）、`combat`（拦截 386、damage 49）、`state_p3_clean`（unsafe 0 / 覆盖率 0.66） |
| 剩余问题 | ① **多人小队真机证据缺失**（`squad_multi` 恒 0，代码+单测有、真机没出现）；② **重规划延迟没有独立埋点**（只有"下一协调轮重规划"的代码推断） |

## P3 主线与决策地图

| 字段 | 内容 |
|---|---|
| 状态 | ✅ **达标**（M01–M05 全成 + 第二座指挥中心**实际建成**；交战局 M06→M07 后自动退回 M04/M05） |
| 对应代码 | `graph/campaign.py`、`graph/decision_map.py`、`graph/rules_fallback.py`、`graph/behavior_tree.py` |
| 测试命令 | `python -m unittest adjutant_coordinator.tests.test_campaign_mainline adjutant_coordinator.tests.test_campaign_no_model_development` |
| 真实对局证据 | `state_p3_clean`（M01–M05 + 第二基地）、`outcome`（打到结算：**战败**，M01/M02/M03/M06 完成、M04/M07 阻塞） |
| 剩余问题 | 战败根因（见下 F1）未修；M04/M07 在战败局阻塞 |

---

## 未完成项（按优先级，每条都要有真实对局证据才算完）

| # | 项 | 状态 | 对应代码 | 测试命令 | 真实对局证据 | 剩余问题 |
|---|---|---|---|---|---|---|
| F1 | 交战行为修复：被闸门挡住时转集结/回防；`enemy_on_route` 接入紧急类型 | ⏸ **待用户批准**（属玩法行为） | `graph/movement.py`、`graph/nodes.py`、`graph/campaign.py` | 待定 | 暂无（方案见验收报告 §4.8） | 需批准后才动 |
| F2 | 面板"外部副官识别"实机验证（面板显示"运行中（外部进程）"而非"尚未启动"） | ✅ 完成 | `source/ui/AdjutantButton.gd`（`_ensure_authority_port`/`_authority_reports_attachment`）、`net/DebugControlServer.gd`（`op=status` 增 `match_id`） | `python -m unittest adjutant_coordinator.tests.test_port_registry` | **未完成**（前次验证被并发锁/打断） | 需一轮干净对局核对：客户端口 vs 服端口 match_id 对齐 |
| F3 | 多人小队推进的真机证据（`squad_multi > 0`） | ⬜ 未开始 | `graph/movement.py::squad_hop`、`nodes._gate_movement` | `test_safe_movement.py::SquadTest` | 无 | 真机没出现多人编队 |
| F4 | 重规划延迟埋点（到达→下一次规划、路径失败→下一次规划） | ⬜ 未开始 | `graph/movement.py`、`deploy/agent_runner.py` | 待补 | 无 | 目前只有代码推断 |
| F5 | 整局胜负结算路径 | ✅ 已验证（战败） | `graph/campaign.py::M07` 证据 | — | `outcome` 局：`local_result="Defeat"`、单位归零 | 胜负**赢**的一侧未验证（需要打赢） |

## 已完成项（保留证据索引）

| # | 项 | 证据 |
|---|---|---|
| D1 | 批量下发从未生效的根因修复 | `state_p3_clean`：`batch.calls=21` |
| D2 | `arrival`/`path_failed` 事件实现（此前显式"不支持"） | `state_p3_clean`：arrival 118 |
| D3 | 侦察先行覆盖率口径修复（曾出现 455.0 假比率） | 干净集成局 0.66 |
| D4 | E2E 夹具腐烂修复 + 守门测试 | `e2e_dual_layer` PASS=21/FAIL=0；`tests/test_e2e_fixture.py` |
| D5 | 验收工装与面板的端口/pidfile/日志三维隔离 + 并发拒绝锁 | `config/dev_ports.json`、`tests/test_port_registry.py` |
| D6 | 玩家接管 + 显式 reacquire 真机验证 | `takeover_tk2`（租约 active→false、副官继续指挥）、E2E 21/21 |
## F2 根因(5): 长度前缀/分片解码/await/玩家名/x or []
