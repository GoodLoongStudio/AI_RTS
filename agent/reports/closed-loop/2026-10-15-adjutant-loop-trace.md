# AI 副官：循环、分支与卡点回放

用户要求：用带分支的循环图查看副官如何作出决策，并找到循环卡在哪个节点、哪个条件或哪条失败返回路径。

本轮已建立中文流程图与 2,078 轮离线时间回放，核验出一个具体入口缺口：本局 374 次调用的已保存上下文中，D2「经济恢复」可选次数为 **0**，其中 371 份明确列为暂不可选。案例中工人 6、M01 已完成，无法满足现有恢复条件；矿场失败、交货为 0 也不能通过该条件开启恢复。

**范围状态：诊断图和离线回放已验证；运行时逐节点追踪、无进展判定及自动恢复仍待实现，产品状态保持 `needs-review`。** 不能把本轮图形交付当作副官行为已修复。原始观察审计仍为 18/20、rc=2。

- [打开交互时间回放](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-loop-trace.html)
- [现有调度循环原图](G:/AIRTS/AI_RTS/agent/reports/closed-loop/figures/adjutant-runtime-loop.png)
- [必须具备的目标反馈循环原图](G:/AIRTS/AI_RTS/agent/reports/closed-loop/figures/adjutant-goal-feedback-loop.png)
- [本局经济恢复入口卡点原图](G:/AIRTS/AI_RTS/agent/reports/closed-loop/figures/adjutant-economy-breakpoint.png)
- [既有 374 次完整中文输出表](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-chinese-timeline.html)

## 如何看这张循环图

打开时间回放后，可拖动滑块选择轮次、上一轮／下一轮，或输入观察秒数。点击「定位经济卡点」会选到第 1,592 轮、观察 07:37.268、tick 9557。此按钮按案例输入 tick 定位世界记录，**不是**把 strategy-0028 的返回绑定到该轮；该轮最近已完成调用实际是 tactics-0224。

左侧显示源码定义的调度图，黄色仅标明分类日志证明的路由选择。图内可滚动，切换轮次后会定位到分类和选中的分支；右侧保留余额、实体数、原日志行号、最近完成调用及该调用的候选路线和不可选原因。事件与状态可展开查看，最近状态带采样年龄。

三张图的含义必须分别理解：

| 图 | 依据 | 能证明什么 |
|---|---|---|
| 现有调度循环 | 本局同版本源码及 event_classified 日志 | 程序定义的连接，以及每轮有证据的路由选择 |
| 目标反馈循环 | 本轮明确的设计要求 | 成功、等待、失败、超时、恢复应该如何闭合；不证明这些分支已全部实现 |
| 经济恢复卡点 | 当前条件、保存的调用上下文和后续观察 | D2 为什么未开放，以及需要补充的反馈入口；虚线均是待实现建议 |

图展示程序可观测的决策和执行证据。缺少的节点进入／退出时间及任务因果关系保持缺失，不补写模型内部推理。

## 已找到的入口缺口

实际条件位于 [campaign.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/campaign.py:1825)：

```text
needs_recovery = 受袭次数 > 0
                 AND M01 状态不是 done
                 AND 工人数 < 2
```

[decision_map.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/decision_map.py:149) 再要求 `needs_recovery` 与 `has_worker`，才能开放 D2。

strategy-0028 输入 tick 9557 的已存证据为：工人 6、M01 done、矿场任务失败、已完工矿场数 0、矿场交货数 0。保存的上下文没有 `under_attack_total`，所以不声明其数值；仅工人数及 M01 两个条件就足以确定这里的 `needs_recovery` 为 false。

| 证据 | 本局数值／原文 | 含义 |
|---|---|---|
| D2 在调用上下文的可选次数 | 0 / 374 | 不能简单归因为模型不肯选择经济恢复 |
| D2 被明确列入暂不可选 | 371 / 374 | 剩余 3 份未明确列锁定原因，也没有把 D2 列为可选 |
| 返回结果解码目标为 D2 | 0 | 与候选入口缺口一致，不单独证明所有恢复逻辑不存在 |
| strategy-0028 理由原文 | 当前计划仍有效，任务状态异常但未影响施压阶段目标，维持现有计划不变。 | 模型观察到异常仍维持原计划，需继续核验目标失效和恢复的执行条件 |
| 同份输入的计划期限 | valid_until_tick=4480；输入 tick=9557 | 理由中的「仍有效」不能替代期限判断 |
| 余额末段平台 | 余额 100，持续约 472.979 秒 | 余额样本没有变化；不能单凭余额推出每秒收入为 0 |
| 矿场完工／交货 | 0 / 0 | 与余额平台分开陈述的实际经济链证据 |

原件：[strategy-0028 输入](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/attempts/strategy-0028.context.json)、[strategy-0028 结果](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02/attempts/strategy-0028.result.json)。

另一个需要保留的判据问题是：M01 在 tick 914 被判完成，原日志证据为「采集命令已被权威接受（1 条）且观测到工人」。这只支持命令已接受和工人存在，不支持交货已经发生。后续修复应区分「采集任务已分配」和「经济循环已建立」。本轮没有改变里程碑定义。

## 为什么有循环、有框架仍会卡住

[graph.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/graph.py:404) 已使用 LangGraph StateGraph 和 MemorySaver。单次图调用从读取事实进入分类，分流到战略、战术、等待或玩家协调，再仲裁、下发、读回执、推进里程碑、保存并结束；宿主启动下一轮。循环返回边属于宿主调度，不是图内无限递归。

现有 [decision_map.py 的说明](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/decision_map.py:17) 明确：`success / failure / exit` 是进日志与面板的文本。它们表达设计意图，本身不等于可执行的条件判断和跳转。实际进展和恢复逻辑还必须沿调用处逐项核验；不能从存在这些字符串推断所有失败边已接通，也不能反过来宣称工程完全没有恢复机制。

| 本局已核对的调度／事件 | 次数 |
|---|---:|
| 世界／图轮次 | 2,078 |
| 战略路由 | 379 |
| 战术路由 | 736 |
| 等待路由 | 963 |
| 玩家打断路由 | 0 |
| 决策日志条目 | 54,801 |
| 命令回执记录 | 120 |
| 模型／适配器调用 | 374：战略 39、战术 335 |
| plan_hold / plan_adopted | 33 / 1 |
| strategy_result_rejected / strategy_degraded | 4 / 1 |
| task_patch_applied | 332 |
| reserve_blocked / intent_dropped | 1,754 / 1,853 |
| build_backoff | 5 |

路由轮次不能当成模型调用次数：分类节点也运行规则基线，且异步返回可在后续轮次消费。战略为 MiniCPM，战术走 Laya；不能把 335 次战术调用称为 335 次 MiniCPM 对话。

## 后续运行时必须落实的分支合同

对每个正在执行的目标，至少保存下面这些字段，并由程序根据真实事实判断去向。自然语言理由用于解释，不能替代判据。

| 要回答的问题 | 最小记录／条件 |
|---|---|
| 现在在哪个节点、在做哪个目标 | node_id、goal_id、task_id、parent_task_id、plan_version |
| 为什么能走／不能走某条边 | 候选 edge_id、每项入口条件的实际值、判定结果、原因码 |
| 这次为何选择这条边 | selected_edge、可公开的选择理由、输入事实版本／tick |
| 下发后有没有被接受 | command_id、receipt_id、accepted/rejected 及拒绝原因；与结果记录分开 |
| 什么才算成功 | success_predicate 与事实证据，例如矿场完工、新单位部署、第一次交货 |
| 正常等待还是停滞 | entered_at、last_progress_at、deadline、progress_metric；正在建造等正常阶段不能仅因余额不变就报卡死 |
| 失败／超时后去哪里 | failure_edge、timeout_edge、recovery_node、替代方案及其入口判据 |
| 如何避免反复撞同一个失败点 | retry_count、retry_budget、失败方案指纹、冷却／失效条件 |
| 没有合法恢复路线怎么办 | blocked/degraded、缺失证据、恢复评估条件、向玩家展示的短原因 |
| 是否真正闭环 | 结果证据关联回原 task_id；成功关闭，失败进入诊断，正常等待保持，条件变化重新评估 |

本轮图包含三条基本返回路径：达成目标后推进；有进展且未到期限则等待；失败、超时或长期无进展则诊断，检查替代方案。没有方案时保留失败状态和缺失信息，在条件变化时重新评估。

防停滞的判定应主要由程序执行，不要求小模型每轮重新阅读完整历史。模型只需当前目标、相关事实差异、可选分支、失败摘要和必要的任务证据；图的全量历史由程序保存并回放。本轮未修改上下文构建或增加模型请求。

验收必须覆盖：正常有进展的等待不误报；关键任务失败能进诊断；超时和无进展能走恢复；恢复入口不满足时显示实际缺项；重复失败受重试预算约束；玩家打断和退出仍可结束。这些是后续实现门槛，尚无本轮真实 Match 证明。

## 导出、独立核验与浏览器验证

开发根为 `G:/AIRTS/AI_RTS`。本轮变更限定为 [离线导出器](G:/AIRTS/AI_RTS/tools/dev/export_adjutant_loop_trace.py)、三张图的 `.mmd/.md/.png/.svg`、本报告及 `.html/.json/.manifest.json`，以及对应计划／提示词。没有修改游戏、副官运行源码、模型服务和交付成品。

| 基线 → 本轮 | 结果 |
|---|---|
| 已有原始记录 → 可按时间选择的图轮次 | 原有 2,078 轮 → 同样 2,078 轮可回放，无新增游戏数据 |
| 调度与分支解释 → 源码／实测／建议分别标明 | 三张图，实际路由黄色高亮，恢复建议虚线标注 |
| D2 不可选 → 条件值和入口原因核验 | 0/374 可选，371 明确锁定；8 组真实条件表达式真值表通过 |
| 原始证据保护 | 831 份输入文件 SHA-256 前后相同 |
| 本局源码身份 | graph.py、nodes.py、decision_map.py、campaign.py 四份与原局冻结 SHA-256 相同 |
| 产品行为 | 未修改；没有新的行为指标或 champion 晋级 |

命令与退出码（完整路径保留以便复现；重导出应使用新的输出目录和图目录，工具拒绝覆盖现有产物）：

```text
git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel
rc=0，结果 G:/AIRTS/AI_RTS

D:/software/anaconda3/python.exe -B G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target <本轮实际目标绝对路径>
rc=0，导出器、计划、报告及图目录均通过开发边界检查

D:/software/anaconda3/python.exe -B G:/AIRTS/AI_RTS/tools/dev/export_adjutant_loop_trace.py --run C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02 --output G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-loop-trace.md
rc=0，生成 HTML、JSON、manifest 和图的 Markdown；本报告另行编写

npm exec --offline --yes --package=@mermaid-js/mermaid-cli -- mmdc -i <三图之一.mmd> -o <对应.png 或 .svg> -p C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/loop-graph-puppeteer.json -b white --size 1500 -s 1.5
三图各渲染 PNG 和 SVG，6 次 rc=0

D:/software/anaconda3/python.exe -B C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/verify_loop_trace.py
rc=0，19/19 独立检查通过，不导入导出器

node --check C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/loop-trace-browser-script.js
rc=0，页面脚本语法通过

node C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/verify_loop_trace_browser.cjs
rc=0，20/20 浏览器检查通过，关闭本轮自有浏览器
```

独立校验逐条核对原始世界记录、分类序列、原始日志行号、余额与实体数、时间不取未来状态／调用、全部上下文的 D2 候选事实、条件真值表、原始与输出哈希及图源一致性。[独立结果 JSON](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/loop-trace-independent-verification.json)。

浏览器校验覆盖首尾轮次、前后切换、按秒跳转、案例按钮、最近调用菜单、上下文缺项显示、原始事件展开、图片加载、三个实际路由的黄色节点与样式，以及图内滚动。[浏览器结果 JSON](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/loop-trace-browser-verification.json)。

首次浏览器验证发现 Mermaid 12 给 SVG 节点 ID 添加前缀，导致高亮未命中；已精确修正节点匹配并处理 SVG 内联颜色优先级，复验确认实际显示黄色。初次 D2 字符串断言误设「暂不可选」后紧接 D2，改为逐条检查真实列表，保留 0/374 判据。流程图改为独立滚动，保持右侧证据可见；静态图增加原图入口。首次 mmdc 使用旧 `-w` 参数报错，按 v12 接口改用 `--size` 后六次渲染通过，未放宽任何图或证据判据。

已实际打开并查看三张原图和浏览器截图：[经济卡点回放截图](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/loop-trace-case.png)、[图内分支截图](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/loop-trace-graph-detail.png)。截图可见分类菱形与战略节点为黄色，右侧明确展示工人 6、M01 完成、D2 不可选，以及当前原件行号。

## 三图逐节点、逐箭头复核

使用 [mermaid-diagram 技能](C:/Users/Administrator/.codex/skills/mermaid-diagram/SKILL.md)。三图 `.mmd` 均无 Markdown 包裹，与对应 `.md` 中的 Mermaid 围栏逐字符一致；PNG/SVG 经 CLI 渲染，并打开 PNG 查看。以下各项是实际审图记录。

### 现有调度循环：14 节点、18 箭头

节点逐项核对：`ingest` 读取世界事实与事件；`campaign` 更新阶段与候选路线；`classify` 分类并运行规则；`strategy` 战略异步提交／等结果；`tactics` 战术任务修改；`wait` 等待而非停止既有任务；`reconcile` 协调玩家控制；`paused` 暂停判定；`arbitrate` 合法性／资源／重复门禁；`dispatch` 下发；`receipt` 回执与任务进度；`advance` 推进里程碑；`checkpoint` 保存；`host` 本次调用结束。均与源码语义相符，两个判定使用菱形。

| # | 箭头 | 复核 |
|---:|---|---|
| 1 | ingest → campaign | 正确，读取后更新 |
| 2 | campaign → classify | 正确 |
| 3 | classify → strategy | 正确，379 轮 |
| 4 | classify → tactics | 正确，736 轮 |
| 5 | classify → wait | 正确，963 轮 |
| 6 | classify → reconcile | 正确，本局 0 轮 |
| 7 | reconcile → paused | 正确，展开条件分流语义 |
| 8 | paused 是 → checkpoint | 正确 |
| 9 | paused 否 → arbitrate | 正确 |
| 10 | strategy → arbitrate | 正确 |
| 11 | tactics → arbitrate | 正确 |
| 12 | wait → arbitrate | 正确 |
| 13 | arbitrate → dispatch | 正确 |
| 14 | dispatch → receipt | 正确 |
| 15 | receipt → advance | 正确 |
| 16 | advance → checkpoint | 正确 |
| 17 | checkpoint → host | 正确，结束本次图调用 |
| 18 | host ⇢ ingest | 正确，虚线明确是宿主下一轮，不冒充图内边 |

### 目标反馈循环：12 节点、17 箭头

节点逐项核对：`facts` 新事实；`goal` 目标优先级仍适用；`choose` 满足条件的方案；`task` 目标／判据／期限；`gate` 合法资源门禁；`execute` 动作与回执；`progress` 后续事实核验；`success` 关闭推进；`waiting` 有进展的等待；`diagnose` 原因与失败证据；`alternate` 替代方案；`blocked` 保留失败和缺失信息。四个判定均为菱形，诊断与受阻为红色，全部属于要求合同。

| # | 箭头 | 复核 |
|---:|---|---|
| 1 | facts → goal | 正确，先核验目标 |
| 2 | goal 否 → diagnose | 正确，前提失效需诊断 |
| 3 | goal 是 → choose | 正确 |
| 4 | choose → task | 正确，形成可追踪任务 |
| 5 | task → gate | 正确 |
| 6 | gate 否 → diagnose | 正确，拒绝原因必须留存 |
| 7 | gate 是 → execute | 正确 |
| 8 | execute → progress | 正确，回执后核验结果 |
| 9 | progress 达成 → success | 正确，要求结果证据 |
| 10 | progress 有进展未到期 → waiting | 正确 |
| 11 | progress 失败／超时／无进展 → diagnose | 正确 |
| 12 | success → facts | 正确，继续下一轮 |
| 13 | waiting → facts | 正确，等待也复查事实 |
| 14 | diagnose → alternate | 正确 |
| 15 | alternate 有 → choose | 正确，排除已证实失败的方案 |
| 16 | alternate 没有／证据不足 → blocked | 正确，保留状态 |
| 17 | blocked 条件变化 → facts | 正确，条件变化后重评 |

### 经济卡点：9 节点、10 箭头

节点逐项核对：`observed` 工人 6／矿场失败／交货 0；`condition` 当前三项 AND 条件；`entry` D2 入口；`recovery` D2 恢复候选；`unavailable` 未进入候选；`decision` 在既有候选和计划内选择；`repeat` 已记录维持战略／重复采集；`result` 末段余额及交货；`stall` 待补的无进展诊断入口。事实节点和规则节点与原件一致，`stall` 明确是建议。

| # | 箭头 | 复核 |
|---:|---|---|
| 1 | observed → entry | 正确，案例事实送入条件判断 |
| 2 | condition → entry | 正确，说明入口规则 |
| 3 | entry 条件成立 → recovery | 正确，明确本案例不满足 |
| 4 | entry 条件不成立 → unavailable | 正确，实际上下文支持 |
| 5 | unavailable → decision | 正确，缺失候选的影响 |
| 6 | decision → repeat | 正确，概括已记录输出，不声称精确调用因果 |
| 7 | repeat → result | 正确，后续观察，不将余额平台当收入测量 |
| 8 | result → observed | 正确，反复评估相同未满足条件 |
| 9 | result ⇢ stall | 正确，虚线标明需要新增、本轮未实现 |
| 10 | stall ⇢ recovery | 正确，虚线建议，需再次评估可执行性 |

三图文件正确性、箭头方向、节点文案、成功／等待／失败覆盖、中文可读性和间距均通过。每图评分 **9/10，ACCEPT**：长回路需要滚动或打开原图查看，这是已披露的轻微阅读成本；无错向箭头、缺失主分支或标签遮挡。浏览器单独截图静态图时可能包含页面悬浮导航，审图依据为同时实际打开的原始 PNG。

## 证据边界、共享工作区与晋级结论

事件按「本次分类到下次分类前」分组，表示日志区段，不等于任务因果链。异步结果可以属于早先任务；最近完成调用只是时间相邻。世界 tick 可重复，本工具按完整轮次序列核对，不把相同 tick 的多轮合并。没有各节点 enter/exit 日志，不显示逐节点精确耗时，也不能凭离线图判定某节点进程挂死。

共享工作区有大量既有未提交改动；检查后仅写本任务自有导出、图、计划和报告，没有 reset、清理或覆盖其他文件。四份关键运行源码仍匹配原局冻结版本，831 份输入证据哈希保持。本轮只启动并关闭自有无头浏览器，没有重启游戏、模型服务或结束用户实例。

按仓库 RSI 文档类例外，本轮未重跑真实 Match、Godot 构建、全量游戏回归或新 10 分钟观察。因此「运行时能准确报卡点并自行恢复」仍未验收；必须在实际接入节点追踪和分支判定后，按关键补丁闸门重新采集真实对局证据。本轮接受诊断图及离线工具，不提升产品 champion，连续未提升计数保持原有值，未将文档轮冒充产品候选轮。原观察的 18/20、rc=2 不变。
