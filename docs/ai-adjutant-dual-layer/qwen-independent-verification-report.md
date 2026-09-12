# Qwen 独立验证与审计报告（Hermes AI 副官闭环）

日期：2026-09-08。执行：CodeBuddy（GLM-5.3-Flash，独立审计任务，不承担功能开发）。
审计对象：`docs/ai-adjutant-dual-layer/hermes-full-loop-acceptance-report.md`（下称"验收报告"）、技能 `临时文件夹/hermes_skill/ai-rts-commander/`、协调器 `source/adjutant_coordinator/`、运行证据 `tmp_logs/hermes_loop_evidence/`。
约束遵守：全程未连接现网 24571/24771、未触碰 /home/ubuntu/AI_RTS；本地只使用隔离端口 24575/24577/24578；未输出任何凭证。

## 总判定：PARTIAL

核心结论：**Hermes 控制链路本身可信**——命令单一入口 adjutant_command、身份字段完整、只读链一致、隔离回收干净、无绕过 Hermes 的技能路径、无现网误触证据。但存在 4 项真实缺陷/失败，依判定规则不得写 PASS：

1. Godot 协议冒烟测试 1 项失败（build NotVisible）；
2. C# tests/core 18 项失败（技能段 17 项为记忆悬案，队友声称修复但实测仍在）；
3. 运行证据 provider_calls.jsonl 跨局污染，验收报告 §2/§4 的局 4/5 模型调用统计失真；
4. rts_verify.py 的 last_positions.json 绕过 AI_RTS_SKILL_STATE_DIR。

---

## 1. 静态审计（10 项）

| # | 检查项 | 结论 | 证据 |
| --- | --- | --- | --- |
| 1 | 游戏动作只经 rts_act.py→adjutant_command | **PASS** | rts_common.py:241-272 `send_command` 只发 `op=adjutant_command`；rts_ctl.py:28-36 旧 op（move/gather/build/produce/attack/attack_move/stop/start/screenshot/click/drag/key/adjutant_batch）本地拒绝 exit 2 且零网络请求；rts_plan/rts_verify 纯只读 |
| 2 | Hermes 技能真实调用 5 脚本 | **PASS** | SKILL.md 铁律+闭环流程只授权 rts_ctl/rts_plan/rts_act/rts_verify；runner 任务书（hermes_round_runner.py:32-42）强制使用 |
| 3 | 独立 Python 绕过脚本 | **PASS（附说明）** | 技能目录内无绕过脚本。仓库内历史工具：autoplay/movement_e2e_check.py（默认 24572）、e2e_driver/driver.py（24568）、e2e_dual_layer.py:308（24569/24570/24572，`op=move` 用于模拟玩家手动命令以测 PlayerOverride）、dev/adjutant_exploration.py（走 adjutant_command ✓）。均不在 Hermes 技能授权内、均不指向现网端口。注意：**服务器协议层旧 op 仍可直接调用**（人类玩家手动命令路径，有 PlayerOverride 租约联动），属已知设计而非缺陷 |
| 4 | Strategy/Tactics 分离真实 Provider | **PASS** | rts_plan.py:94 `load_provider("strategy", STRATEGY_PROMPT)`；rts_act.py:157 `load_provider("tactics", TACTICS_PROMPT)`；均为 HttpModelProvider，缺凭证时 error 且不发请求（test_missing_api_key_is_error_without_request） |
| 5 | AI_RTS_SKILL_STATE_DIR 每局独立状态目录 | **PASS（1 缺陷）** | rts_common.py:20 支持；缺陷见 §6-D |
| 6 | 四脚本独立状态目录 | **PASS（1 缺陷）** | rts_act/rts_plan/rts_verify 经 rts_common.STATE_DIR；hermes_round_runner.py:200-203 每局 `round_dir/skill_state`+注入 env；例外：rts_verify.py:89 last_positions.json 固定写脚本目录 |
| 7 | 共享证据文件跨局清理/覆盖路径 | **PARTIAL** | runner 归档为 copy 不 delete（hermes_round_runner.py:230-238），实测局 B 不清局 A（§5）；但 **provider_calls.jsonl 跨局累积污染实锤**（§4） |
| 8 | 命令身份字段完整 | **PASS** | send_command 构造 command_id/request_id/match_id/player_id/rules_version/plan_version/task_id/based_on_snapshot/issued_tick/expires_tick/action/params（rts_common.py:245-259）；test_rts_skill.py:135-141 逐字段断言；服务器端二次校验（DebugControlServer.gd:1369-1453） |
| 9 | 凭证泄漏面 | **PASS** | 仓库代码搜索 STEPFUN_API_KEY/sk-/AI_ADJUTANT_API_KEY 0 命中；凭证仅 env 或 ~/.hermes/.env 读取（rts_common.py:117-120），进程内注入；http_provider.py 落日志前 redact_headers/redact_text（测试 test_logs_never_contain_secret）；证据目录 73 文件+技能目录+协调器日志目录扫描 0 命中；git ls-files 无凭证类文件；test_retired_token_absent_from_tracked_files OK |
| 10 | 端口硬校验防误连 24571 | **PARTIAL** | 默认 SERVER_TCP=24577（rts_common.py:22）+ runner 启动预检（hermes_round_runner.py:99-109,163-164）+ SKILL.md 铁律 5。但 **无显式 24571 黑名单**：AI_RTS_ADJ_PORT 可被设为任意端口而无校验拦截。属纵深防御缺口（Hermes 实际运行于服务器，127.0.0.1:24571 即现网局服，风险真实） |

## 2. 本地自动化验证（真实退出码）

| 命令 | 结果 | 判定 |
| --- | --- | --- |
| `python -m unittest discover -s source/adjutant_coordinator/tests`（AI_RTS 下） | Ran 136 tests, OK | **PASS**（EXIT=0） |
| `python -m py_compile`（技能 7 个 .py） | 无输出 | **PASS**（EXIT=0） |
| `git diff --check` | 仅 1 条 CRLF 提示（AdjutantButton.gd，非空白错误） | **PASS**（EXIT=0） |
| 客户端凭证冒烟 `python -m unittest source.adjutant_coordinator.tests.test_client_credential_source -v` | Ran 2 tests, OK | **PASS**（EXIT=0） |
| Godot 协议冒烟 `Godot_..._console.exe --headless --path AI_RTS res://tests/automated/AdjutantCommandProtocolSmokeTest.tscn -- --debugport 24577` | `Adjutant command protocol smoke test completed: 1 failure(s)`；失败项："副官 build（服务器直执行）应被接受（实际 status=Rejected reason=NotVisible）"；退出另有 "5 resources still in use at exit" | **FAIL**（EXIT=1） |
| `dotnet run --project tests/core`（真实自写 runner；`dotnet test` 对该 Exe 项目不发现任何测试，无意义） | AI_RTS.Core 59 tests **17 failures**（延迟伤害/周期段+友伤倍率）；Balance 17 tests **1 failure**（"演示直接命中弹头默认禁止友伤"）；Structure 6/6、Construction 6/6、Production 6/6、Rally 5/5、Input 11/11、ControlGroup 7/7、WorldQuery 15/15、MatchOutcome 15/15、Battlefield 3/3 | **FAIL**（EXIT=1） |
| 补充故障注入测试（本审计新增，`tmp_logs/qwen_audit/test_qwen_injection.py`） | Ran 15 tests, OK | **PASS**（EXIT=0） |

关于 NotVisible：`git merge-base --is-ancestor` 证明可见性校验（GodotStructurePlacementWorldPort.cs:67，引入提交 1e04831）早于测试最后修改（f59e042），即测试最后一次交付时就未通过——非本审计引入，也不被验收报告 §8 披露（§8 只列了 136 单测/py_compile/规则导出冒烟）。

## 3. 故障注入矩阵（17 场景）

| 场景 | 覆盖层 | 结果 | 证据 |
| --- | --- | --- | --- |
| 空模型响应 | http_provider/chat_client | PASS | test_empty_body_normalized；test_empty_object_is_empty_response_not_error（空对象→COMPLETED+payload=None→技能不提交）；补充测试 test_empty_content_rejected/test_empty_body_from_provider_is_error |
| 非法 JSON | http_provider | PASS | test_invalid_json_normalized → OUTCOME_ERROR |
| finish_reason=length 截断 | chat_client | PASS | test_truncated_output_rejected → 502（本轮补充复验） |
| HTTP 451/502/500 | http_provider | PASS | test_http_400/500_normalized + 补充测试 test_http_451/502/500；451 归一化 error，5xx reason 触发 rts_act 单次重试、451 不重试（test_5xx_flag_drives_single_retry_in_rts_act_semantics） |
| Provider 超时 | http_provider | PASS | test_timeout_normalized → OUTCOME_TIMEOUT |
| Provider 迟到结果 | host/coordinator | PASS | test_late_result_discarded_after_timeout、test_stale_plan_late_arrival_discarded、test_pending_result_settled_after_deadline_is_discarded、test_cancelled_after_response_wins |
| 计划版本倒退 | rts_common/PlanStore | PASS | test_adopt_plan_rejects_regression（旧计划保持不变）；test_version_must_increase_old_plan_rejected；补充复验 |
| rules_version 漂移 | protocol/服务器 | PASS | test_stale_rules_version_rejected（Python 包络）；GDScript RulesVersionStale（协议冒烟 46-47 行）；补充 test_rules_version_drift_rejected |
| snapshot_id 倒退 | protocol/服务器 | PASS（按设计放行） | 设计语义=仅拒绝未来快照（SnapshotInFuture，协议冒烟 52-53 行+test_future_snapshot_rejected），倒退由 expires_tick 兜底；补充 test_past_snapshot_allowed_by_design 固定该行为。审计认可该语义，但要求文档明确 |
| 重复 command_id | 服务器幂等账本 | PASS | 同 ID 同参数→原回执+idempotent_replay、异参数→DuplicateConflict（协议冒烟 60-69 行） |
| PlayerOverride 后旧租约命令 | 服务器租约+host | PASS | 手动命令取消租约→PlayerOverride 拒绝→reacquire=true 显式重接管（协议冒烟 71-77 行）；test_player_override_blocks_then_reacquire |
| 非法 scene_path | 服务器受信任映射 | PASS | UntrustedScene（协议冒烟 85-87 行；DebugControlServer.gd:1566-1568） |
| 非法 producer | 动态生产关系 | PASS | InvalidProducer（协议冒烟 82-84 行；DebugControlServer.gd:1570-1583） |
| 越界 build | C# StructurePlacement | PASS | StructurePlacementServiceTests 6/6（含越界）；验收报告局 1 真实 37 条 OutOfBounds 拦截佐证 |
| 资源不足 | C# Economy/Production | PASS | Production service tests 6/6、CastSkillRejectsInsufficientResourcesWithoutStartingCooldown PASS |
| tactical 截断 | rts_act | PASS（本轮新增） | 补充测试 test_truncated_tactical_blocks_everything：截断→exit 1、不调模型、零命令 |
| 断线重连身份指纹不一致 | transport/host | PASS | test_identity_drift_rejects_reconnect、test_identity_drift_blocks_reconnect |

## 4. 证据完整性复算

复算器：`tmp_logs/qwen_audit/qwen_evidence_audit.py`（+逐局 `verify_round.py` 重跑）。

### 4.1 逐局 verify_round.py 复算（与验收报告 §2/辅助局对照）

| 局 | 退出码 | verdict | 与验收报告一致 |
| --- | --- | --- | --- |
| hermes_pilot/round_1 | 1 | FAIL | ✓ |
| hermes_pilot/round_2 | 1 | FAIL | ✓ |
| hermes_run1/round_1 | 1 | FAIL | ✓ |
| hermes_run1/round_2 | 1 | FAIL | ✓ |
| hermes_run1/round_3 | 1 | FAIL | ✓ |
| hermes_run1/round_4 | 1 | FAIL | ✓ |
| hermes_run1/round_5 | **0** | **PASS** | ✓（唯一 PASS；core_pass 9/9 全 true；coverage 0.118→0.928） |

### 4.2 一致性与真实状态对应

- timeline server_tick/snapshot_id 零倒退：round_1（128 样本）、round_4（86）、round_5（171）全部 PASS。
- match_id/rules_version 跨 receipts/provider_calls/final_rules 一致（rules_version 全程 `c710239f…`）。
- accepted↔真实状态：局 1 gather 3/3 且余额 Δ1400、move 64/64、produce 3/3；局 4/5 失败命令保留（UntrustedScene/InvalidProducer/OutOfBounds/ResourceNotFound 等真实 reason）——与验收报告 §3 一致。
- 失败局如实标注、无"单局 PASS 写成整体 PASS"表述（验收报告明确写"不能写整体通过"）✓。

### 4.3 发现的真实缺陷：provider_calls.jsonl 跨局污染

- round_4 归档 35 条 = 局 4 纯净 13 条（match 23060079，17:45:29–17:51:11）+ **局 3 的 22 条**（match 821d81cb，17:29:04–17:43:14）；
- round_5 归档 52 条 = 局 5 纯净 17 条（match 8604094c，17:54:17–18:01:31）+ 局 4 的 13 条 + 局 3 的 22 条；
- 三局时间严格顺序无重叠 → 非并发混入，而是该文件跨局追加且未按局重置（receipts.jsonl 每局干净：29 条/18 条均为本局 match_id）。
- **后果：验收报告 §2 表格"局 4 28/35、局 5 41/52（战略9+战术43）"与 §4 的 52 次统计系对被污染文件整体计数**（52 行总 completed=41、error=11 与局 3+4+5 合计吻合；局 5 纯净实为：战略 completed 5、战术 completed 8+error 4）。报告的局 4/5 模型调用统计不可从证据复算。

## 5. 隔离端口运行回归（本地 Windows，无 Hermes、零游戏命令）

命令：`python tmp_logs/qwen_audit/qwen_isolated_runner.py --out-root tmp_logs/qwen_audit/runs`
结果：run_id=`qwen_readonly_20260908_210138`，**EXIT=0 全步 PASS**：

- 端口预检 24575/24577/24578 空闲 ✓；
- server(UDP 24575/TCP 24577)+client(TCP 24578) 启动、双侧 networked ✓；
- `{"op":"start","with_ai":false}` → ok=true ✓；
- 槽位严格 `1,0,0,0`（server.log"配置 [1,0,0,0]"）✓；
- 只读链 rules→tactical→strategic→status 两轮采样：tactical/strategic 携带完整身份（match_id `11813a30…`、rules_version `1dcfabfb…`），两轮一致；snapshot/tick 单调 [(1,405),(2,406),(3,709),(4,710)] ✓；rules 观测含 match_id/rules_version 但协议上无 snapshot_id/server_tick；status 无身份字段（只有 players/human 等）——验收报告 §5"match_id/rules_version 跨观测一致"的表述对 status 不成立（表述过宽，记录为偏差）；
- 旧接口拒绝：rts_ctl.py move/gather/build/produce 全部 exit 2 + "已被 v5 技能禁用"，零请求发出 ✓；
- 回收：taskkill /F /T 树杀 → ALL_STOPPED=true、三端口 bind 复测全部释放、PID 37540/53316 无残留 ✓；
- 证据写入全新 run_id 目录，未覆盖任何已有证据 ✓。

## 6. 状态目录并行隔离测试

命令：`python -m unittest qwen_state_dir_test`（`tmp_logs/qwen_audit/qwen_state_dir_test.py`）。**Ran 4 tests, OK（EXIT=0）**。

- 目录 A/B 交替读写：A 的 plan/receipts/seen/provider_calls/timeline 对 B 完全不可见，反之亦然；A 目录字节级不变 ✓；
- 模拟局 A 异常退出（无归档）→ 局 B 正常运行：局 A 已落盘证据逐文件字节不变；归档（copy）后源目录不清空 ✓；
- 默认回退行为（未设 env → STATE_DIR=脚本目录）显式可见——这正是局 3 型覆盖的历史根源，现 runner 每局独立目录已规避；
- **缺陷探针确认：rts_verify.py:89 `prev_path = Path(__file__).resolve().parent / "last_positions.json"` 绕过 STATE_DIR**——并行两局或跨局会共享该文件（影响 moving_units 辅助输出，不影响覆盖率主口径）。

## 7. 与验收报告不一致之处

| # | 验收报告表述 | 实测 | 严重度 |
| --- | --- | --- | --- |
| 1 | §4：局 5 provider_calls "战略9+战术43=52，completed 41、error 11" | 52 行是被跨局污染文件的总行数（局 3+4+5）；局 5 纯净=17 条（战略 5 完成、战术 8 完成/4 错） | 高（统计失真） |
| 2 | §2：局 4 "模型调用 28/35" | 局 4 纯净=13 条（2 战略完成、10 战术完成、1 战术错） | 高（同源） |
| 3 | §5："match_id/rules_version 跨观测一致（rules/tactical/strategic/status 四件套）" | status 协议上不含任何身份字段；rules 不含 snapshot_id/server_tick；身份一致仅在 tactical/strategic 成立 | 低（表述过宽） |
| 4 | §8 测试表 | 未披露 Godot 协议冒烟 1 failure（build NotVisible）与 C# tests/core 17+1 failures | 中（测试面披露不全） |
| 5 | §6.4/悬案：技能段 17 失败"aefeabd 声称已修复" | 实测仍 17 failures（同段同数），未修复 | 中 |
| 6 | §7 现网保护 | 与本次静态复核相符（默认 24577+预检+TLS 硬校验），但"硬校验"实为默认值+预检组合，无 24571 显式黑名单 | 低（口径） |

其余关键结论（局 5 唯一 PASS、失败局如实 FAIL、探索覆盖率仅局 5 达标、真实状态变化证据、现网端口零触碰声明）经独立复算**成立**。

## 8. 真实缺陷清单（文件/行号）

| ID | 缺陷 | 位置 | 影响 |
| --- | --- | --- | --- |
| A | 协议冒烟测试 build 用例被 NotVisible 拒绝，测试处于失败态 | tests/automated/AdjutantCommandProtocolSmokeTest.gd:99-101；校验源 GodotStructurePlacementWorldPort.cs:67 | 现有测试套件非全绿；服务器直执行 build 的冒烟覆盖失效 |
| B | C# 技能段 17 失败（延迟伤害/周期段/友伤倍率）+ Balance 1 失败 | tests/core/Program.cs 段（AI_RTS.Core 59 tests）；"演示直接命中弹头默认禁止友伤" | 与 AllowsFriendlyDamage 改动相关的回归未清 |
| C | provider_calls.jsonl 跨局累积污染并随归档进入证据 | 技能落盘层（rts_common.py:143 _append_jsonl 无按局隔离失效场景）+ 归档链 | 跨局模型统计失真；"证据属于同一局"验收项对 provider_calls 不成立 |
| D | last_positions.json 绕过 AI_RTS_SKILL_STATE_DIR | rts_verify.py:89 | 并行/跨局共享移动检测基线 |
| E | 无 24571 显式黑名单；AI_RTS_ADJ_PORT 可设任意值 | rts_common.py:22 | 纵深防御缺口（在服务器上误设 env 时无最后防线） |
| F | rts_act 退出码语义：有发送即 exit 0（`0 if accepted>0 or sent>0`），即便全部被服务器拒绝 | rts_act.py:226 | Hermes 侧需解析 JSON 才能感知全拒；轻微 |

## 9. 绕过与现网误触核查

- **未发现任何真实游戏命令绕过 Hermes→rts_act.py→adjutant_command 链**：技能 5 脚本中唯一命令出口为 send_command(op=adjutant_command)；旧 op 在技能层全部本地拒绝（实测 exit 2）；仓库内直接发旧 op 的脚本（e2e_dual_layer.py:308 等）均为独立测试工具、使用隔离端口 24568-24572、不处于 Hermes 授权路径。服务器协议层保留旧 op 为人类玩家手动命令路径（有租约联动），属设计而非绕过。
- **未发现现网误触证据**：本次审计全部网络活动限于本机 127.0.0.1 隔离端口 24575/24577/24578 与 headless 测试；未向 101.43.121.102 发起任何连接；未读取/修改 /home/ubuntu/AI_RTS 相关内容；证据目录扫描无任何指向 24571/24771 的连接记录或命令行痕迹。验收报告的现网保护声明与静态代码复核相符（E 留口径保留）。

## 10. 测试后环境核查

- 隔离对局进程已树杀，PID 37540/53316 不存在，三端口可重新 bind；
- 本审计新增文件仅 `tmp_logs/qwen_audit/`（审计脚本+只读复算结果+新 run_id 证据），未修改任何正式平衡数据、技能脚本、协调器代码与已有证据；临时状态目录已随测试自清理（tempfile）。

## 11. 未解决问题

1. 缺陷 A/B 的修复归属（Godot 测试预设 vs 可见性校验时序；C# 延迟伤害段与友伤规则）需功能负责人处理，本审计不改代码；
2. provider_calls 跨局污染的精确机制需在服务器侧 runner/技能落盘层进一步定位（本地复现仅能确认事实与时间线）；
3. 验收报告局 4/5 模型调用统计如需可信数字，应基于 per-match_id 过滤后重算（纯净值已列于 §4.3）；
4. 防线 E（24571 黑名单）与 D（last_positions 状态目录化）是否补齐由负责人决策。
