# AI 副官战略改造：独立验证报告（P0 首段）

- 执行者：外部验证 AI（2026-10-15），证据目录 `G:/AIRTS/AI_RTS/agent/runs/20261015-adjutant-external-validation-01`
- 交接文件：`agent/prompts/2026-10-15-adjutant-validation-handoff.md`（已完整读取并执行）
- 范围纪律：未修改任何产品源码、正式测试断言、默认配置或历史证据；全部整改仅在本证据目录内的新工具副本上进行。

## 1. 工程身份与交接核验（P0-1/P0-2，全部通过）

检查命令与 rc：

| 检查 | 结果 |
|---|---|
| `git rev-parse --show-toplevel` | `G:/AIRTS/AI_RTS`，rc=0 |
| `git status --short` | 共享未提交工作区（大量他人未提交改动，未触碰），rc=0 |
| `tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS` | decision=allow，rc=0 |

交接原件 SHA256 逐一核验，**全部一致**：

| 文件 | 结果 |
|---|---|
| `source/adjutant_coordinator/deploy/agent_runner.py` | `4fc7b7d9…` 一致 |
| `source/adjutant_coordinator/graph/strategy_variants.py` | `36275cc9…` 一致 |
| `source/adjutant_coordinator/graph/graph.py` | `379ddfb0…` 一致（原 MemorySaver 口径） |
| `A/decision.json` | `161c089f…` 一致，内容 `accepted-local-normal-runner-S1-S2-independent`，S1=44、S2=226/165/54/15 |
| `A/candidate-source-freeze.json` | `7f04ba8e…` 一致 |
| `S/summary.json` | `817445ab…` 一致 |
| `V/…joint-audit.json`、`verification.md` | `98e08a8e…`、`7e6a1a63…` 一致 |
| 视频草稿与审计件（5 个） | 全部一致 |

**1263 文件 freeze 实地核验**（新探针 `p0_verify_freeze.py`，结果 `p0-freeze-verification.json`）：1263/1263 SHA 匹配、0 SHA 漂移、0 mtime 漂移、12 DLL，check rc=0。历史接受证据真实且与当前源码一致；本轮新测试与之分开报告。

## 2. F1/F2 反例：实际执行证实（新证据，此前仅为静态审阅）

脚本 `p0_f1_f2_counterexamples.py`，原始结果 `p0-f1-f2-counterexample-results.json`，合成样本在 `p0-counterexamples/`（仅合成，非游戏录像）：

- **F1 证实**：10 帧/5FPS（2s 容器）喂给现有 `record_playtest.py review --end 24` → rc=0、index.end=2.0、10 entries（截断被当成功）；10FPS/120 帧容器 → rc=0、index.fps=10.0、end=12.0。driver 只查 reviewer OS0，不会拒绝。
- **F2 证实**：两个 stage 键指向同一无关 pass 文件（decision 文本 unrelated、freeze 不同）时，draft 的 `validate_signal` 不抛错直接通过。

## 3. 修复门禁与正负资格（新工具，仅本目录）

`video1263_gate_fixed.py`：`verify_review_index`（视频身份、FPS=5、start=0/end=24/step=0.2、120 条顺序唯一帧索引 0..119、全部原帧与联系表存在非空）+ `validate_signal_strict`（信号 schema/label/freeze + 两个 stage 键必须钉死本轮已接受 decision 原件并核对内容：pass=true、decision 文本、S1=44、S2 合计 460、skips=0）+ `make_green_signal`。

资格 `p0_gate_qualification.py` → `p0-gate-qualification.json`：**14/14 通过**（正例 P1/P2；负例 N1 短容器、N2 错 FPS、N3 缺帧、N4 entries 截断、N5 错视频、N6 end 截断、N7 缺联系表、N8 无关 pass 文件、N9 SHA 错、N10 pass=false、N11 decision 文本错、N12 freeze 不匹配，全部按预期拒绝）。原工具原件与全局 `tools/dev/record_playtest.py` 未改动。

## 4. 首段后台实录：真实 Match、24s、5FPS、120 帧（vid11，全绿）

- 运行声明：`green-signal-fresh05-extval01-vid11.json`（绑定 label、fresh05 freeze `7f04ba8e…`、已接受 decision `161c089f…`，经严格门禁校验后由我的 launcher 消费）。
- 证据：`fresh05-extval01-vid11-video/`（video/clip-01.mp4、review/clip-01/ 120 帧+10 联系表、logs、instances、summary.json、actions/states/requests jsonl）；launcher 层 `fresh05-extval01-vid11-video-launch/launch-final.json`。
- 身份与退出：driver 自然 OS0；server 41500 / client 41508 / recorder 39360 / reviewer 40640 全部自然 OS0；强清 0；隔离桌面、未激活/未置顶/不动真实鼠标；engine `--path G:/AIRTS/AI_RTS`；180wall 内完成（driver 墙钟 ≈50s）；原始 stderr 0 字节；forbidden/Fatal 扫描通过；EventAPI/WER 通过；lease stop+join 完成；1263 SHA/mtime 前后稳定。
- video_gate：120 帧 / 5FPS / 24s / 0 重复帧 / PrintWindow，后台可变帧成立。
- review_index_gate（F1 整改）：全覆盖 0..23.8s 通过。
- 动作（command-level）：t=3.22s Move（PendingAuthority，result.accepted=1）；状态对账 origin (381.8, 68.9) → (393.2, 80.2)，位移 16.0，到达（距 dest<2）于 t≈9.5s 前；t=18.39s 正常退局请求；末态 match=false/networked=false；menu 正常。

### 实看记录（满足"extracted_not_reviewed → 实际回看"要求）

10 张联系表（sheet-001..010，12 帧一张，5FPS=0.2s 粒度）**全部打开查看**，并抽看原帧 `frame-0000016.jpg`（t=3.2s，Move 下发时，无人机在基地左上）与 `frame-0000097.jpg`（t=19.4s，无人机已至基地右下）。可见时间线：

- t=0–3.0：正常开局，HQ 穹顶+无人机+HUD（资源 10000、建造菜单、小地图）；
- t=3.6–19.4：无人机从基地左上向右下连续位移，画面与 states.jsonl 数值一致；
- t≈20.2（帧 101）：主菜单出现（对应 t=18.39 退局请求），持续到 t=23.8 结束；
- 未发现缺帧/重复帧/黑屏/异常画面；无音轨（PrintWindow 录制固有限制）。

视觉验收：**画面对照动作/状态一致，本段通过**（等级仍为 command-level；UI 点选/框选/右键/持续按键未验，不冒称玩家试玩）。

## 5. 工具缺口清单（prepared driver 首次真实执行暴露；均为证据工具问题，非产品缺陷）

| # | 缺口 | 证据 | 我的整改（仅本目录副本） |
|---|---|---|---|
| 1 | review 截断当成功（交接 F1） | §2 反例 | `verify_review_index` 全覆盖校验，14/14 资格 |
| 2 | 接受决定可混绑（交接 F2） | §2 反例 | `validate_signal_strict` 钉死 decision 身份，14/14 资格 |
| 3 | 单次窗口枚举失败即崩（客户端有 11 个顶层窗口、含两个 50×50 可见辅助窗口，"可见即可捕获"不成立） | vid03/04/05 summary + `window-probe.jsonl`（vid05） | 有界重试 20s + 探针留痕 + 主窗口面积阈值 ≥400×300，保留 `find_window` 交叉校验 |
| 4 | launcher 以字面路径校验 recorder `--output`，temp 8.3 短名（ADMINI~1）误报 | vid06 launch-final errors | realpath+normcase 归一化比较，其余选项逐字校验 |
| 5 | recorder/reviewer 输出被 `record_playtest.evidence_path` 拒绝（只允许 agent/runs），draft 却把视频放 C temp | vid07 `logs/recorder.log` | 视频与 review 产物改写本证据目录；C temp 仅日志/实例 |
| 6 | 开局加载期 DCS 单请求 5s 超时会中断轮询（大图加载常>5s） | vid08 summary（TimeoutError: timed out） | 轮询改 `dcs_safe` 容忍瞬态并留痕 `poll-transients.jsonl`；验收检查保持严格 |
| 7 | 客户端 `--autojoin` 一次性尝试，服务端加载慢时永久错过 | vid09 requests.jsonl（networked=false 直至超时）+ 服务端日志仍在加载 | 轮询过半未加入时按主 runner 同款公开 API `NetSession.join` 显式重join一次 |

vid03–vid10 为失败轮（first_red 记录保留于各自 `-video/summary.json` 与 `-video-launch/launch-final.json`），vid11 为首个全绿实录。

## 6. 给主代理的观察项（按重要度排序；均不阻塞本验证继续）

1. **内存压力信号（环境/产品待查）**：vid10 全流程同样全绿（4 子进程自然 OS0、无强清），但 Windows EventAPI 捕获 EventID 1001 `RADAR_PRE_LEAK_64`（Level=4 信息级，P1=Godot exe；上报 PID 40728 实为 taskhostw，非拥有进程）。与交接 §6 已知 Memory02/长局 RSS 增长缺口方向一致。vid11 同判据通过；建议主代理在长局验证中关注客户端内存。证据：`fresh05-extval01-vid10-video/summary.json`（wer 节点）、`final-windows-crash-events.json`。
2. **prepared driver 从未真实运行**：视频工装此前仅有离线资格（63/63）；本次首跑连续暴露 7 个工具缺口（§5）。建议实现方在正式采纳前按 §5 清单复核原件（我未改动原件）。
3. **产品无新增缺陷证据**：vid11 全部产品行为判据（正常开局、Move 接受、导航到达、正常退局、自然退出、日志干净、1263 稳定）均通过，未发现需要修复的产品问题。

## 7. P1：真实本地模型同输入比较（本轮新证据）

### 7.0 环境与模型身份（只读核实）

- 产品 `.env.local` 配置端点 `127.0.0.1:11436`，**当前无任何进程监听 11436**；本机现有 Ollama 服务在 **11434**，模型 `minicpm5-adj-16k:latest`（2.5GB）在列。未重启/未更换服务、未改任何配置文件。
- 模型身份实测（`ollama show`）：**2.5B 参数（"2B"实为 2.5B）、Q8_0、ctx 16384、temperature 0、num_predict 512**。
- 密钥仅装入进程环境，未打印、未入证据。

### 7.1 冻结输入（披露：重建，非边界捕获）

accepted 主运行归档确认**不含完整 provider context**（`runner-evidence-final.json` strategy 行只有 proposal/meta/selection）。据此以产品代码路径重建：fresh05 checkpoint（state@tick817）+ 同运行 r1-opening-observation 摘要 → `build_strategy_context` → `prepare_selection`，context SHA `8734c4782d3153cb23d584ff9d2723a828fa1d96f1453be8f0d67cf8b3298f6c`（10728B，2 候选：C-ECO 47 分 / C-RECON 15 分，无 KEEP 候选）。六模式消费**同一冻结事实**；plan 保留完整输出合同。

### 7.2 六模式结果（`p1-model-comparison-results.json`，有界 8 次真实 HTTP 调用）

| 模式 | 实际调用 | 结果 | 证据 |
|---|---|---|---|
| choice（产品默认 relabel=P1/Pn，2 轮均衡置换） | 2×HTTP | **均 `choice_out_of_enum` → rules_fallback**；raw=`{"choice":"D6"}`（抓事实摘要里的路线 ID，两轮相同，temperature 0 可复现） | transport_records |
| choice（canonical 标签对照，1 次） | 1×HTTP | **model_native 合法**，chosen=C-ECO，339ms | `p1-choice-canonical-probe.json` |
| template | 1×HTTP | **model_native**，template=recon→C-RECON，77ms | meta |
| score | 0（分差 32>margin 8，程序直选） | program_direct，未仲裁 | meta.gap=32 |
| score_only | 0（零模型/零密钥） | plan strat-c-eco | meta.model_called=false |
| rules | 0 | rules-mainline-default | plan_id |
| plan（pydantic_ai 完整合同） | 1×HTTP | **model_native 合法 StrategicPlan**，1464ms，maintain_current=true | raw_text sha f7133bd1… |
| usage 探针 | 1×HTTP | prompt 276 tok / completion 7 tok / finish=stop | 补充独立调用，已披露 |

**给主代理的产品级发现（按重要度）**：
1. **choice 合同在产品默认 relabel 显示（P1..Pn）下对真实 2B 全部越界**——模型答路线 ID 而非显示 ID；canonical 语义标签下合法。fake 选择器恒回 `{"choice":"P1"}`，S1 44/44 无法暴露此问题。建议核查 `VariantRequestProvider(relabel=not selection_canonical_labels)` 默认值与 CHOICE_SYSTEM 提示词的组合。
2. 冷启动/首请求会吃满 15s 战略预算（Ollama 需加载模型）；keep_alive=Forever 时后续 0.3~3.7s。实局若模型未预热，首轮必降级。

## 8. P2：执行链路与长局（本轮新证据，真实模型 plan+tactics on）

派生驱动 `p2_execution_driver.py`（由 accepted 主支持草稿最小派生，diff 全部披露）：`--provider real --strategy-mode plan --tactics on`，runner 进程环境把三个 BASE_URL 覆盖到 11434（`.env.local` 未改），绿信号严格门禁，watchdog=720wall+RSS 采样。

### 8.1 执行链路追踪（p2run4 短局 + p2long7 长局）

- **request→plan**：strategy propose_plan 真实调用 model_native（1.3–3.7s），plan_id/task_ids 齐全。
- **合法 KEEP**：真实模型在整局长局中**全部输出 maintain_current=true**（9 次中 6 次成功、3 次 ModelInvalidOutput 降级，ticks 1656/3544/5442）——与交接"合法 KEEP"口径一致，未伪造 Accepted。
- **task/intent→权威 receipt**：rule-build-vehicle_factory / rule-fill-scout 等意图经 `intent_arbitration` 接受、`command_timing` 下发、权威回执 Accepted（action=build、action=move[translated_from=scout]）。
- **实际结果**：长局 tick 6067 时 13 单位（含 **vehicle_factory 已建成、tank、anti_air_turret、worker**）、campaign 推进 M01→M06（施压）、economy/build/scout/military 四轨 running。执行在真实发生，但战略层未产生新计划（全 KEEP），**战略执行收益仍无证据**（与交接预判一致）。
- **tactics on（四列）**：`propose_task_patch` 数十次全部 ok（274–561ms；**首次调用 31.6s**——Ollama 串行排队+冷加载）。短局（~45s）内首次 tactics 调用无法完成，属延迟事实非缺陷判定。
- **降级路径真实工作**：ModelInvalidOutput 3 次→规则层继续驱动（`strategy_failures_degradation` 留痕），无炸图。

### 8.2 长局稳定性（p2long7，240+ 模拟秒，watchdog 720s 内完成）

- 内存：runner RSS 峰值 **4825MB**（torch/Laya 加载，末样本 4825.7 稳定）、client 446MB、server 440MB——240s 内无明显泄漏趋势；与交接 Memory02 缺口方向的数据已采集。
- **唯一红项（判据未放宽）**：scanner 门禁 3 次活动局 `scan_errors` 增量（`scan_last_error=timeout`，1001 样本中 3 次≈0.3%，scan_hz 降至 5.3）+1 次退局后增量。原 gate 语义（活动局任何增量即红）保持，本验证**未放宽**；按交接要求作为产品观察项上报。
- 局内加成（Augment Draft）在 ~90 模拟秒弹出让树暂停（墙钟倒计时后自动选推荐项恢复）——短局覆盖不到、长局必现；我的 harness 以暂停窗口分类记录（披露：仅窗口内 scan 增量分类，窗口外仍硬红）。
- 退局/自然退出：菜单退局、server 自然 OS0、runner launcher/main 双自然 OS0。

### 8.3 P2 失败轮（全部保留证据）

p2run1（wrapper evidence-root 契约）、p2run2/3（tactics 判据时机）、p2run4（tactics 记录时机）、p2long1（加成暂停未建模）、p2long2（加载期 DCS 轮询瞬态）、p2long3/4（暂停窗口分类修复中）、p2long5/6（降级分类与 selection 空值）——每轮 summary/launch-final 均在对应目录，过程性工具缺口与 P0 §5 同类（prepared/derived harness 首次真实执行的暴露）。

## 9. 未验证项 / 限制（更新）

- 视频无音轨；UI-player 链路未走通，等级仅 command-level。
- vid10 的 RADAR_PRE_LEAK_64 归因未定。
- **权限负例**（错误 as_player 拒绝）、**同客户端重开（round 2）在真实模型下**、跨图/跨 seed、玩家接管、S3 全量正式清单：本轮未执行（长局唯一红为 scanner 真实观察，不为凑绿继续刷轮；S2 460 项已在冻结不变源码上接受，无需重跑）。
- 实局矩阵（同 map/seed 多模式对照）未做全：真实模型 plan 模式已实局验证，rules/score_only 等无模型模式未在实局成对对照。
- 真实 2B 的战略执行收益：**无证据**（模型全程合法 KEEP + 3 次结构化降级，未产生新战略计划）。
- 全局 champion 未晋级、default plan 未改变。

## 10. 回滚方式

本报告涉及的所有新文件都在 `agent/runs/20261015-adjutant-external-validation-01/`（git 忽略目录）+ 一个唯一命名的 wrapper 证据目录 `agent/runs/20261014-resume-transport-prep/fresh05-extval01-p2*-runner-private-exit`（wrapper 契约要求，未覆盖任何已有产物）。删除即完全回滚；产品源码、正式断言、用户模型配置零改动。
