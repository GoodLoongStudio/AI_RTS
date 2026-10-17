# 副官第一阶段 E1–E4 修复与权威重放隔离 — 2026-10-17

状态：**needs-review**。本次直接修改了实现、补齐回归并执行实机验证；专项逻辑通过不等于第一阶段整体通过。最终 600 秒运行、交互产物与独立运行时复核在本报告末节汇总。未提升 champion，没有把未通过项交回给用户操作。

## 结果与交付入口

- [最终运行目录](../../runs/2026-10-17-adjutant-phase1-repair/round-replay/final-600/)
- [独立逻辑复核：29 项通过](../../runs/2026-10-17-adjutant-phase1-repair/independent-review/candidate-review-status.json)
- [完整独立复核经过](../../runs/2026-10-17-adjutant-phase1-repair/independent-review/report.md)
- [最终源码解析及 SHA256](../../runs/2026-10-17-adjutant-phase1-repair/final-source-parse.json)
- [原生回归严格审计](../../runs/2026-10-17-adjutant-phase1-repair/godot-strict-audit.json)

## 修复行为和权威合同

E1：`PendingAuthority`、`Unknown`、空回执都是未结论状态。继续查询实际提交的 command；同一 command 可以从未结论推进到 Accepted/Rejected。终态只结算一次，迟到 Pending 不覆盖终态。超时记录仍保留可查询身份，不能把暂未收到结果当作拒绝。

E2：恢复授权生成稳定的 attempt ID，不能仅用 tick 判断是否是新尝试。新授权清空当前意图、已提交命令及结算集合，旧尝试保存最多 16 条历史。dispatch 前登记实际 command 并冻结本地 attempt 标签；调度未下发只增加 schedule_waits，不扣执行失败预算。客户端或模型传来的 attempt 标签不能自行取得权威性。

新鲜长测另外暴露了权威服务的 intent 重放缓存：新授权即使换了 command ID，沿用 intent ID 仍会取回旧 command 的回执。修复后恢复 intent 采用 `原ID:recovery-<attempt摘要>`，同次授权稳定，不同授权隔离，普通任务 ID 不变。返回的 intent/command/match/player 与实际提交不符时保留原件、标记身份不符，本次实际 command 记为 Unknown 并继续查询，不能给异属回执补上当前标签后结算。

E3：`observation_view.normalized_units` 的实体字典键进入 `campaign.build_facts`，再进入任务判据。指定 SiteA 的任务仅使用 SiteA 事实；SiteB 完工不关闭 SiteA；SiteA 消失或未知保持 unknown，重现后可继续观察。

E4：完工数只统计 `constructed is True`。False 是在建；None/缺字段是未知。未知数量单独保留，不能用实体存在或真值转换提前完成任务或晋升阶段。

权威链仍是现有 LangGraph → task_loop → 实际 dispatch → DebugControlServer receipt → owned-player facts。Accepted 只证明命令被接受；建筑完工、实体部署、经济交货分别依赖后续权威事实。没有添加第二套经济或任务权威，没有提高模型轮询频率。

## 精确改动范围

| 文件 | 变化 |
|---|---|
| `source/adjutant_coordinator/graph/task_loop.py` | attempt 生命周期、有界历史、非终态推进、实际提交预算、指定工地与未知事实、异属回执隔离 |
| `source/adjutant_coordinator/graph/nodes.py` | 提交前冻结关联、pending/recheck、异常 Unknown、按 attempt 隔离权威 intent、回执身份验证 |
| `source/adjutant_coordinator/graph/state.py` | 提交及 pending 关联状态字段 |
| `source/adjutant_coordinator/graph/campaign.py` | 实体键接线及 True/False/unknown 完工计数 |
| `source/adjutant_coordinator/tests/test_task_loop.py` | E1/E2/E3/E4 与 transport/重放边界反例 |
| `source/adjutant_coordinator/tests/test_campaign_mainline.py` | 完工正反例及指定工地事实链；完成基地 fixture 明确设 True |
| `tools/dev/adjutant_observe.py` | 新鲜实例证据、后台窗口录制与有界退出排空 |
| `tools/dev/export_adjutant_timeline.py` | 精确上下文关联多个 HTTP 重试，保留未匹配请求原件，不以邻近时间猜关联 |
| `tools/dev/export_adjutant_chinese_timeline.py` | 动态统计、完整原始输入/输出/异常、缺失文件诚实标记 |
| `tools/dev/export_adjutant_runtime_trace.py` | 受阻筛选修复；去掉旧样本硬编码及把间隔称正常等待的错误解释 |

`observation_view.py` 的既有改动原样保留，本轮没有以它伪造完工事实。运行辅助脚本、截图、日志和差异放在专属 runs 目录。主产品源码没有在最终冻结后继续修改。

## 基线、反例和冻结身份

初始 HEAD 为 `4851de361b4c924cde0eacbe2d113b14fc6c9798`，分支 `yyp_test`，存在共享未提交改动。15:38:24 出现外部共享提交 `8552bca19237a6bfd906c1089ca24c0cb349ba8e`，包含此前部分修复；本代理未提交、切分支或重置。不能仅凭当前 git diff 还原本轮全部归属，应结合 baseline 和冻结 hash。

| 产品文件 | 最终 SHA256 |
|---|---|
| nodes.py | `cfeb1acd0144e6dcb5b80c9b9ca9e4f34abd24b617f56df7537cff1b9a146d14` |
| task_loop.py | `5a1c6ff338c61f5278f3370290e763f66e357f2167dea6fcd73bd9a001efe894` |
| campaign.py | `6db8924b25645b323dc1884395d6e45f732cb734c694d0ea3e4f4eb8d50e0fd4` |
| state.py | `d81e754209dc18d85524c7f60f03b46b8228d6f1aaa98ae03bf2116a8b955401` |

新发现的 authority replay 独立基线为 3/3 失败、rc=1；修复后同类 3/3 通过。最终独立检查共 22+3+4=29 项通过，三组前后四文件 hash 一致。原 15 项探针中两项固定 ID 断言已不符合新的身份合同，原脚本/原结果保留；复核仅替换这两项 ID 假设，并保留原业务和预算判据，没有修改判据掩盖行为失败。

最初 E2/E3/E4 曾合并后才做新局，违反逐补丁 S1 顺序。此流程偏差不能事后补写成已经逐项通过。随后新 replay 逻辑补丁及 foreign match/player 补充均执行了新鲜 S1，最终 30 秒 S1 的游戏与 runner rc=0、无强制结束、无残留、源码未变；其中恢复命令明确返回 `intent_replay=false`。

## 测试与回归

| 检查 | 结果和证据 |
|---|---|
| AST 解析 | 10 文件通过，rc=0，`final-source-parse.json` |
| 最终专项 Python | 241 项通过，rc=0，`round-replay/related-tests-frozen.log` |
| 最终独立逻辑 | 29 项通过，rc=0，见独立审查 |
| 全量 Python | 1148 项，1 failure、3 errors、1 skipped，rc=1，`round-replay/python-full.log` |
| .NET 构建 | 0 警告/0 错误，23.91 秒，rc=0，`dotnet-build.log` |
| Core 测试 | rc=1；3 个生产失败及 21 个 balance/config 断言，`core-tests.log`；缺少证明它们均为既有红的基线 |
| Core 边界检查 | rc=0，56 文件无 Godot 依赖，`core-boundary-final.log` |
| legacy authority 检查 | rc=1，26 处未登记写入，`legacy-authority-final.log` |
| Godot 128 项 | 全部有启动/日志记录，严格可确认通过 78 项；其余失败或证据不全，rc=1；详见严格审计 |

全量 Python 的四项红与先前基线一致：build_identity/task_progress 缺 `capture_build_site` 导入，economy_bootstrap 缺模块，campaign_no_model_development 期望 phases≥3 实际2。基线位于 `agent/runs/2026-10-15-adjutant-phase1/baseline.md`。全量日志在最后两行身份防护前完成，最终 241 项及独立 29 项在最终冻结后完成，不宣称全量1148均在最终hash重跑。

主要复现命令（测试目录为 `source/adjutant_coordinator/tests`）：

```text
<airts_agent_venv>/python.exe -X utf8 -B -m unittest test_task_loop test_campaign_mainline test_graph_runtime_fake test_economy_recovery test_decision_trace test_graph_state_checkpoint test_player_interrupt
<airts_agent_venv>/python.exe -X utf8 -B -m unittest discover
dotnet build --no-restore
<anaconda3>/python.exe tools/run_parallel_suites.py --godot <Godot_v4.7.1-stable_mono_win64.exe> --ids all --jobs 4 --no-recheck --out <runroot>/godot-all
```

原生回归存在明确环境限制：四项初跑曾暂停，已判初样无效并串行重跑；重跑只有 helicopter-command 通过，另外三项超时。net-infantry 初跑缺专用 server，重试已建本轮 server，但自动副官产生额外负载，末行 JSON 又遇 G: I/O 错误，保留为未确认/失败。Tee 写入“设备未就绪”使三个后期 console rc 缺失，不能用外壳 rc=0 或日志 marker 猜其通过。9 项 runner 标 pass 的日志含 forbidden 输出，严格审计按失败。native 运行跨过共享提交和 Python 补丁时间，不能称整棵冻结源码的全绿回归。

## 实机证据的适用范围

旧 `final-600` 是 replay 修复前版本：600.000 秒、2106 轮、81483 追踪事件；有89 Accepted/4 Rejected，其中一条拒绝为旧 intent replay，不能说四次新执行。矿场完工0、交货0、经济建立false；第一条矿场拒绝至诊断3.552秒/1图轮。三次 rebuild_refinery 无下发，执行预算0/3、调度等待3/3。视频只覆盖375秒，后段窗口隐藏后录制停止。旧报告、原审计与证据保持原样，只用于对照，不能为最终候选背书。

新的最终运行使用正常 Main→Play→Loading→Match 回调，源码 `--path G:/AIRTS/AI_RTS`，真实 LangGraph、plan 模式、战术开启、现有11434模型服务。模型 `minicpm5-adj-16k`，manifest `ff4ea8cf1265af9e9a514a3edd5536bae3134ee63de3a731cf83f18eaf528950`，num_ctx16384、num_predict512、temperature0、top_p0.95；地图/seed配置与实例命令保存在 room-setup/processes 中。

实际模拟时钟通过只读 MCP 获取 `Match.get_simulation_msec()`，与 Engine physics_frames 分开。原自动时钟线程提前退出，补充采样从墙钟113.193秒开始；0–113秒无直接时钟采样，不能以20Hz×tick补造整段模拟秒数。暂停记录不消耗实际模拟时间。

不注入系统输入、不抢前台、不恢复最小化窗口。录制是后台窗口证据，未验收正常玩家手工操作流程。自然长测没有自动覆盖所有 Pending/Unknown 乱序、SiteA/SiteB 反例；那些由独立逻辑探针和正式回归覆盖，不能冒称长测均触发。

## Candidate/champion 与共享工作区

`cand-phase1-e-repair` 因新鲜实机发现旧权威 intent replay 被拒绝。后续 `cand-phase1-f-replay` 的专项逻辑通过，但全量回归未通过，保持 needs-review、不提升。连续未提升计数为2，原 champion 身份及文件保持不变。共享工作区保留候选补丁供审阅；没有为“回到 champion”执行破坏性 reset 或覆盖别人的文件，也没有更新打包版。

## 最终运行与产物核对

收尾记录将在本次新运行结束后写入此节：墙钟/实测模拟时段、恢复命令和权威 replay、交货/建造、失败到诊断、视频实看范围、浏览器筛选与原件展开、进程清理、独立运行时结论。尚在运行的结果不提前写 pass。
