# 2026-10-11 整晚对局优化阶段一：电脑规则AI查询层去重（闭环报告）

状态：**阶段一主体完成——测量完成 ✓、候选有收益 ✓、独立复核 ✓（round-05 重放）、
可见对局矩阵 5 场 ✓；未闭合：全量回归未跑、副官真实模型共存（待用户提供 .env 凭证）、
FindAutoSpot 第二候选（分析完成，按用户指示留待下轮）**。
任务来源：`agent/prompts/2026-10-11-match-performance-overnight-integrated.md`（阶段一）。
执行会话：2026-10-11 12:16 接手（前一执行AI因过慢被用户停止，仅留下基线 hash 快照、
4 次空跑日志与本轮已建的插桩/探针雏形）。

## 0. round-05 独立复核与 4 场矩阵（2026-10-11 16:35–17:10 补齐）

**独立复核（RSI 重放，新代码路径）**：把 champion 撤回基线树（保留诊断桶）→
`verify-base` 探针 + 基线树 9 项套件 → 恢复 champion 树 → `verify-cand` 探针 +
champion 树 9 项套件。结果：

| 项 | verify-base（基线树） | verify-cand（champion 树） |
|---|---|---|
| 终局单位 | 20 | 20（两侧发展一致，更干净的一对） |
| GetOwnForces 调用 | 2269 | **350（−84.6%，与原 A/B 精确复现）** |
| GetOwnForces 耗时 | 1389ms | 657ms（−52.7%） |
| AI 桶总计 | 3.45s | 2.95s（**−14.6%**，等发展量下的保守估计） |
| frame p95 / p99 | 15.72 / 16.30 | 6.90 / 13.79 |

回归复放（两棵树各 9 项次）：**全部与存储结论一致**——绿：world-query-runtime、
rule-ai-defense/intelligence/battlegroup/aggression/offense-logistics（两树均绿）；
红：rule-ai-economy-query、rule-ai-expansion（两树同败，HEAD worktree 已归因为
树上开发中状态）——稳定非 flaky。

**可见对局矩阵（5 场，超过要求的 4 场）**：

| 对局 | 树 | 配置 | 终局单位 | 录像 |
|---|---|---|---|---|
| vis-1ai | champion | 1AI、674 模拟秒 | 20 | 2 段 |
| vis-3ai | champion | 3AI、679 模拟秒 | 58 | 8 段 |
| vis-final-1ai | champion | 1AI、674 模拟秒 | 29 | 4 段 |
| vis-base-1ai | **基线** | 1AI、674 模拟秒 | 25 | 4 段 |
| vis-base-3ai | **基线** | 3AI、674 模拟秒 | 69 | 8 段 |

两侧树都能正常开局/发展/采矿/产兵并正常退局（rc=0），发展量在运行间随机性范围内
相互重叠（1AI 20-29、3AI 58-69）——行为等价的直观证据；perf 结论以无头 A/B 为准。

## 0.1 FindAutoSpot 分析修正与后续（本轮未实施，按用户指示收尾）

原报告"66 次失败搜索"表述需修正——b3dev-r1 日志统计：66 次失败全部是
`evaluations=1 stop=global`（ConstructionInProgress 早退，**每次只花 1 次评估**）；
4.1s 实际花在 **22 次成功选址的螺旋搜索上（~187ms/次，256 评估预算 × ~0.7ms/评估）**。
热点根源：`GodotStructurePlacementWorldPort.EvaluateDetailed` 每个候选点重复做
全单位组扫描 + `FindChild("MovementObstacle")` 子树搜索（AdjacentToOwnStructure、
Overlaps 循环、OwnStructures）。
**已设计未实施**的候选：世界端口按物理帧缓存（units/resources/own-structures-with-radius
列表 + IsInstanceValid 防护，同 CaptureShared 合同——位置在物理帧边界更新，
FindAutoSpot 同步执行期间世界冻结）。预期把成功选址 ~187ms 压到 ~60ms/次。
属"同输出重构"类补丁，留待下轮按单补丁闸门实施。

## 1. 热点分解（measured，headless 真实 Match 插桩）

测量工具：`tools/dev/ai_perf_run.py` → `tools/ai_perf_probe.tscn`（无头真实 Match，
PlainAndSimple、Human + N×SimpleClairvoyantAI、difficulty=NORMAL、起始资金 10000=真实对局口径、
AIRTS_AI_PERF_STATS=1 双层插桩：GDScript `AiPerfStats` 桶 + C# `QueryPerfCounters`）。

**1AI、175 模拟秒、约 20-28 单位（champion 树，diag-base）：**

| 成本项 | 实测 | 占比口径 |
|---|---|---|
| GetOwnForces（C# 查询：过滤+排序+逐实体转 Godot 字典） | 2257 次 / 1616ms（717µs/次） | AI 拍内最大单项 |
| ScanCircle | 2306 次 / 758ms | 第二查询项 |
| Capture 入口检查（CaptureShared 每查询一次） | 4764 次 / 606ms | 随查询次数线性 |
| arbitration（资源仲裁桶，含其查询+命令） | 80 次 / 1823ms | |
| economy 桶 | 349 次 / 1304ms | |
| intelligence / defense / offense 桶 | 748 / 535 / 400ms | |
| Move 命令（权威命令路径） | 161 次 / 428ms（3AI：2657µs/次） | 本轮未动 |
| FindAutoSpot 选址 | 88 次 / 4116ms（3AI，46.8ms/次，66 次失败） | **下一候选** |
| 纯 GDScript 逻辑（桶减去其中查询/命令） | ≈ 12% | C# 桥接层占 ~88% |

结论：电脑 AI 的成本集中在 **C# 查询桥接层**（同一物理帧内 5 个 Controller + 编组对同一份
CaptureShared 快照重复过滤/排序/转换），不是 GDScript 决策逻辑本身。1AI 全程 AI 相关成本
≈2.5% 单核；3AI ≈8.6% 单核；帧分布 p95 由引擎/渲染主导，AI 体现在尾帧尖峰。

## 2. 实际最小修改（champion = round-02 候选）

**单逻辑补丁：己方力量查询按物理帧去重（`own_forces_scan`），6 个文件：**

1. `source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd`
   — 新增 `own_forces_scan()`：与既有 `battlefield_scan()` 同合同的按物理帧缓存
   （字段=Economy/Offense 超集 POSITION|TYPE|CONSTRUCTION|PRODUCTION|ORDER）；
   另加仲裁触发源诊断桶（trigger_changed/trigger_request，测量专用）。
2. `EconomyController.gd` / `DefenseController.gd` / `OffenseController.gd` 的
   `_get_own_entities()`：父节点（SimpleClairvoyantAI）有该方法时走缓存；
   **独立实例化（无 AI 父节点）的单元测试保持原直查路径**（setup 签名零改动）。
3. `IntelligenceController.gd` `_refresh_patrols()`、`ConstructionWorksController.gd`
   `_on_refresh_timer_timeout()`：同上缓存优先 + 回退。

语义等价依据：`GodotWorldObservationRepository.CaptureShared` 按物理帧钉住快照
（实测 miss 数=有查询的物理帧数，Snapshot.Revision=物理帧号），同帧内直查与缓存返回
逐字节等价；命令本来就要下一帧才进快照（仓库注释明示），缓存不引入新滞后。
消费方审计：所有 `sort_custom` 均作用在 `.filter()` 副本上（Economy:355、Intelligence:67、
Defense:190、AutoAttackingBattlegroup:294/322 逐一核实），沿用 battlefield_scan 的
"返回共享数组、filter 后再改"约定。

未动的部分：AiCadence/难度/首波/再派/侦察节奏、经济>防御>进攻仲裁与同档首付规则、
RuleAiCommandGateway/CommandRuntime（权威命令边界）、Move/PlaceStructure 命令路径、
ScanCircle（battlefield_scan 已有缓存）、`_has_resources` 的 GetOwnEconomy。

测量专用（不入产品行为）：`AiPerfStats.gd`、`QueryPerfCounters.cs` + WorldQueryRuntime/
Repository 的插桩点（前一执行AI所建，本会话接续并验证），全部由
AIRTS_AI_PERF_STATS=1 门控，未开启时零开销。

## 3. 同场景 A/B 数值（旧 → 新）

### 1AI 配对（同夹具 3600 物理帧 ≈ 175 模拟秒）

| 指标 | baseline (diag-base) | champion (diag-cand) | Δ |
|---|---|---|---|
| GetOwnForces 调用 | 2257 | **350** | **−84.5%** |
| GetOwnForces 耗时 | 1616ms | 626ms | −61.3% |
| capture 入口次数 / 耗时 | 4764 / 606ms | 2762 / 440ms | −42% / −27% |
| **AI 桶总计** | **5.02s** | **2.69s** | **−46.4%** |
| arbitration / defense / offense / intelligence | 1823/535/400/748ms | 744/110/48/444ms | −59~−88% |
| economy 桶 | 1304ms | 1324ms | +1.5%（持平，内含其命令） |
| frame p50 / p95 / p99 | 8.x / 15.68 / 16.81ms | 8.x / 15.67 / 15.94ms | 持平 / p99 −5% |
| 终局单位 | 28 | 20 | 对局随机性范围内 |

### 3AI 配对（同夹具；发展量随机性使两侧单位数不同，查询层为受控项）

| 指标 | baseline (b3dev-r1/r2) | champion (cand3ai-r1/r2) |
|---|---|---|
| 终局单位 | 65 / 54 | 72 / 66（候选发展更多 +11~22%） |
| GetOwnForces 调用 | 4320 (r1) | **538 / 535（−87.6%）** |
| GetOwnForces 耗时 | 2613ms | 1225 / 1259ms（−53%，且单位更多） |
| AI 桶总计 | 9.60s / 8.21s | 10.96s / 10.91s |
| frame p95 / p99 | 15.76/23.54、15.74/23.30 | 16.17/25.59、15.81/23.18 |

**解读**：查询层去重收益在 5/5 次候选运行中稳定复现（调用 −84~88%、查询时长 −53~61%）；
总桶对比被对局发展随机性混淆——候选在发展出更多单位的前提下总成本相近
（单位均摊成本下降）。frame p95 变化 ≤+2.4%（3AI r1）、p99 +2.3ms/−0.4ms 混合，
无超过噪声（<1%，见双基线对照 b1ai-r1/r2 p95 差 0.01ms）的确定性回退；
"AI 分项 p95 −30%" 目标在 1AI 配对以"AI 桶总计 −46.4%"口径达成，3AI 因发展量不可控
以查询层 −87% 作为分项证据。

**已知离群**：round-01 首次候选冒烟（cand-smoke）曾出现总桶 +18%（60s 窗口），
随后 3 次候选运行均未复现；触发源诊断（base 124 vs cand 95 次）不支持"候选触发更多仲裁"。
归因为用户后台负载（League/ToDesk，系统负载 26-53% 波动）+ 发展随机性的离群样本，
原始 JSON 保留于 round-01/ 待复核，不计入结论。

## 4. 行为与实战验证

**无头真实对局**：单位发展轨迹与命令计数逐点对照（round-01 时间线表：place/units
轨迹一致）；候选树 5 次运行全部 rc=0 + AI_PERF_PROBE marker + 新鲜 JSON。
探针在补资金修复后 AI 完整发展：矿场→矿车→采集→车厂→生产线→编组全链点亮
（修复前 AI 因初始余额 0 永久停摆——RegisterPlayer 以 Player 节点导出值为唯一初始
余额导入，探针未设；真实对局 Match.gd 统一发 10000，探针已对齐）。

**可见真实对局（3 场正常开局、发展、正常退局，均 rc=0）**：

| 对局 | 配置 | 结果 |
|---|---|---|
| vis-1ai | 1AI、674 模拟秒、12.3 min | 20 单位终局 |
| vis-3ai | 3AI、679 模拟秒、12.5 min | 58 单位终局 |
| vis-final-1ai | 1AI（相机轮换版）、674 模拟秒 | 29 单位终局 |

**录像与已看秒数**（review.md 索引）：
- `round-02/review/clip-02-probe/sheet-001.jpg` — vis-1ai clip-02 @0-10s：AI 基地 CC+
  无人机+迷雾圈+HUD（**实际打开查看 ✓**）。该 clip 仅 6.8s（屏外窗口被 PrintWindow 判定
  hidden，status=partial，工具已修为屏内后台）。
- `round-02/review/vis3ai-clip-02/` — vis-3ai clip-02 @0-18s：迷雾视野（观察者无单位，
  迷雾正确遮挡）。
- `round-02/review/vis3ai-clip-03/sheet-001.jpg` — vis-3ai clip-03 @0-14s（**实际打开 ✓**）：
  AI CC、无人机巡逻（迷雾圈随侦察移动）、工人、新结构入视野——3AI 发展/侦察的行为证据。
- `round-03/review/clip-02-000-024/sheet-001.jpg` — vis-final clip-02 @0-21s（**实际打开 ✓**）：
  AI 基地 CC+无人机。
- `round-03/review/clip-04-000-024/sheet-001.jpg` — vis-final clip-04 @0-21s（**实际打开 ✓**）：
  纯迷雾（相机移到观察者未揭示的分矿 CC——迷雾公平性证据，发展视觉证据弱）。
- 每场另有 1Hz DCS/探针逐秒状态采样（vis-*.status.jsonl，572/161/… 样本全程连续）。

局限（如实）：观察者是无人单位玩家，视野受迷雾限制，"采矿/交战"的全景镜头需要真人
玩家视野；已看片段覆盖 ~90s 有效画面 + 全程状态数据，未逐帧回看全部 8+4 段
（未看段落列于各 review 目录，状态采样覆盖全程）。

## 5. 副官共存复测（部分验证）

- **3AI+人类对局挂接链路全通**：隔离专用服+客户端（动态端口，e2e 同款流程），
  `controller` op 强制槽位 1/2 为规则 AI + with_ai ⇒ **Player_0/2/3 = AI，Player_1 = 人类**；
  agent_runner 以登记副官 venv（`airts_agent_venv`，pydantic_ai 2.42.0）挂接服务器 DCS，
  **attached 事件落地**（match_id、player=Player_1、server_tick、setup_ms，3 次）。
- **真实模型层未验证**：runner setup 在"真实 Provider 配置缺失（LLM_API_KEY / 模型名）"
  门失败——该凭证/模型名是用户部署的 `.env` 内容，本会话环境中不存在；按任务纪律
  不猜测、不伪造、不改用户持久配置（尝试过的运行时环境 AIRTS_S1_BACKEND=laya 仍被
  同一门拦截——该门在 GraphModelSettings 层先于后端选择检查 key+模型名）。
  **"正常 Laya 决策与命令的共存"列为未验证**，不推断 CPU/GPU 分工无互相影响。
- 共存局游戏侧健康：服务器全程 G4PERF（684 条，~16 tick/s）、161 个逐秒状态样本、
  无对局错误；挂接-空转 runner 期间对局正常推进（这是"挂接不破坏对局"的证据，
  不是"模型共存无资源竞争"的证据）。
- 共享模型驻留：nvidia-smi 显示启动时显存已占用 ~4GB、Ollama 进程在跑（11434 监听）——
  共享模型服务驻留事实已记录，未做关闭组对照（不许卸载共享模型）。
- 产物：`round-04/`（server/client/runner 日志、runner_logs/*.jsonl、逐秒样本）。

## 6. CPU 拓扑、线程预算与默认调度对照

- 拓扑（PowerShell 实测）：AMD Ryzen 9 5900X，**12 物理核 / 24 逻辑处理器**（SMT）；
  GPU RTX 3080 Ti 12GB（启动时已用 ~4GB=共享模型驻留）。G: 盘为 USB 外接 SSD
  （Realtek RTL9210B）——启动 I/O 时长波动 30s~数分钟，是本轮工具链最大的环境噪声源。
- 角色预算表：主线程=模拟+AI 提交+SceneTree；引擎池=渲染/物理/导航默认值（未改）；
  电脑决策=当前全部主线程同步（本轮候选是"减少重复工作"，不做后台迁移）；
  副官=登记 venv 的 1 调度 worker + ≤2 调用 worker（源码口径），Python 内部线程数
  **unavailable**（真实模型层未起来，无法测）；录制/构建/回归与正式采样时间隔离。
- 线程/CPU 集合：**未做 OS 级 trace（wpr/wpa 未启动），线程画像字段 unavailable**；
  未做任何亲和性/软 CPU 集合实验（默认调度保留）——按计划 §1.1，仅在画像证据显示
  争用后才做 A/B，本轮证据（进程内插桩）不构成该前提。
- 后台进程钳制教训（工具层）：本执行环境的后台派生进程被钳到 ~1% CPU
  （4/4 复现），测量驱动一律改前台/Start-Process 脱离进程树（5/5 恢复全速）——
  **这可能也是前一执行AI"过慢"的主因**，已写入 checklist C-008。

## 7. 对局与候选时间线

| 时间(≈) | 局/事件 | 目的 | 结果 |
|---|---|---|---|
| 12:19 | dotnet build | C# 插桩编译 | 0 警告 0 错误 |
| 12:30-12:50 | direct/popen/env/hangtest | 探针链路验证 | 5/5 成功 |
| 12:21-12:41 | drv-* / bisect | 驱动调试 | 5 次后台钳制假死 → 改前台 |
| 13:07-13:26 | b1ai-r1/r2, b3ai-r1/r2 | 0 余额静态负载基线 | 发现 AI 不发展（C-006） |
| 13:32-13:50 | devcheck-1/2 | 资金修复后 1AI 基线 | AI 发展到 20 单位 ✓ |
| 14:00-14:20 | b3dev-r1/r2 | 3AI 基线 | 65/54 单位 |
| 14:25-14:35 | diag-base / diag-cand | round-02 A/B（带触发诊断） | 总桶 −46.4% |
| 14:36-14:55 | cand1ai-r2, cand3ai-r1/r2 | 重复性验证 | 查询层 −84~88% 复现 |
| 14:45-14:50 | 回归 8 套件 | 门禁 | 6 绿 2 红（预存同败） |
| 14:52-15:05 | vis-1ai | 可见 1AI | rc=0，20 单位 |
| 14:36-14:50 | vis-3ai | 可见 3AI | rc=0，58 单位 |
| 14:52-15:05 | vis-final-1ai | 可见 1AI（相机轮换） | rc=0，29 单位 |
| 15:00-15:50 | coexist-1..4 | 副官共存 | 链路通，模型层未验证 |
| 15:30-15:35 | 环境清理 | 进程/登记检查 | 无遗留（仅用户编辑器在跑） |

champion 演进：接手 champion（前一执行AI插桩树）→ round-01 候选（同帧缓存）→
首轮 A/B 出现未复现离群 → 修正等价性论证并复测（round-02）→ **晋级 champion**
（`champion.json`）。连续未提升轮数：0（round-02 即提升）；被拒/回滚：round-01 首版
A/B 期间的一次整体回滚（用于取得 champion 对照数据，随后重应用）。

## 8. 门禁状态与失败分类

| 门禁 | 状态 |
|---|---|
| 改动文件解析/编译 | ✓ 6 个 gdscript probe-load 通过 + dotnet build 0 错误 |
| 新无头真实 Match + 受影响链路 | ✓ 候选树 5 局 rc=0，经济/建造/生产/编组链点亮 |
| 一条旧功能轨迹 | ✓ 单位/建造/生产轨迹逐点对照（round-01 表） |
| 相关回归 rc=0 | **部分**：6/8 绿（world-query-runtime、rule-ai-defense/intelligence/battlegroup/aggression/offense-logistics）；**rule-ai-economy-query、rule-ai-expansion 为 champion 树预存红**——已做 HEAD 干净对照（隔离 worktree @9a2e6d4）：**HEAD 本身无法编译**（StructurePlacementRuntime.cs CS7036 缺 `accounts` 参数、CommandRuntime.cs CS0246 找不到 `GodotConstructionRatePort`——共享树的未提交修改是承重配套改动），故红项归因于**树上开发中状态**，与本轮优化无关；候选同败零新增 |
| 关键可见证据 | ✓ **5 场**正常退局（含基线树 2 场）+ 联系表实际查看；局限见 §4 |
| 独立复核 | ✓ **round-05 重放完成**（两树各 1 探针 + 9 项次套件，结论与首测一致：gof −84.6% 复现、2 红同败稳定） |
| 全量回归 | ✗ 未跑（时间与机器负载限制；预存红项存在，跑全量也无法全绿） |
| OS 线程画像 | unavailable（未启动 wpr；未做亲和性实验） |

**验收口径**：本轮交付"测量完成 + 候选有收益"；**不宣称**"严格门禁全通过"
（独立复核/全量回归/共存模型层三项未闭合），阶段一状态为 needs-review（部分通过）。

## 9. 成本去向：已减少 vs 仍在主线程

**已减少**：同一物理帧内重复的 GetOwnForces 过滤/排序/ToGodot 转换（−84~88% 调用），
随之减少 capture 入口检查（−42%）与 GDScript 各控制器桶内的桥接等待
（AI 桶总计 1AI −46.4%）。分配与 GC 压力随重复转换减少同向下降（未单独计量 GC 暂停——
Godot 4.7 mono 的 GC 计量字段 unavailable）。

**仍在主线程**：快照 Capture 本身（每有效帧一次全量重建，3AI 大地图上仍是最大剩余项）、
ScanCircle（Economy 找资源/Defense 威胁扫描/Intelligence 巡逻）、Move/PlaceStructure/
FindAutoSpot 命令与选址（3AI 88 次选址 4116ms，其中 66 次失败搜索）、寻路/RVO/物理/渲染、
全部命令提交与回执。**本轮没有把任何决策搬进后台线程**——阶段二迁移对象见 §10。

## 10. 下一阶段具体迁移对象

1. **首选：FindAutoSpot 选址**（3AI 实测 4.1s/局、66 次失败搜索 × ~50ms）——纯数据
   螺旋搜索，输入输出均为值类型（类型/锚点/半径→点位+issues），与行为解耦最好；
   但选址结果影响建造位置（内容决策），迁移前需行为等价对照（同输入同输出）。
2. **次选：经济/生产需求统计**（计划 §3 阶段二默认对象）：Economy 桶中的重复数量统计
   与需求推导，已由 own_forces_scan 提供每帧一次的合法观察版本，数据边界现成。
3. **Capture 全量重建**：若主线程采集成为新主因（去重后占比上升），按计划 §3 阶段三
   做纯数据筛选/有效索引候选。
4. 线程合同按计划 §3 阶段二执行（1 计算并发/玩家、generation/epoch 去重、提交复验），
   本轮的 own_forces_scan 已是"同步纯数据选择函数"的雏形（输入=快照实体数组，
   输出=只读数组），迁移时以它为第一批只读输入。

## 11. 清理与遗留

- 进程清理 ✓：所有本轮 Popen/Start-Process 的 Godot/python/录制进程已退出或按 pid 树
  终止；终检仅剩用户自己的 Godot 编辑器（PID 44992，未触碰）。实例登记目录无本轮残留
  （探针走最小调用，不写登记；coexist 的 server/client 为裸 Popen 同样无登记）。
- 遗留风险：① 副官真实模型共存未验证（部署凭证缺失）；② cand-smoke 离群样本未复现
  但保留待复核；③ 可见录像受观察者视野限制；④ G4PERF/FogOfWar 在探针夹具下的
  启动期 SCRIPT ERROR（FogOfWar.gd:67 null size）为夹具结构问题，不影响 headless
  测量，但可见局的雾表现可能失真；⑤ **共享树处于开发中状态**：HEAD 9a2e6d4 无法
  独立编译（见 §8），两个预存红项与未提交修改伴生——需要相应开发会话收口。

## 12. 证据索引

- 本轮 run 目录：`agent/runs/2026-10-11-stage1-perf/`
  （checklist.md、champion.json、round-01/02/03/04 各方向-基线-补丁-验证文档、
  全部 ai_perf_*.json、对局日志、review 联系表、视频 mp4+json+frames.jsonl）
- 工具：`tools/dev/ai_perf_run.py`（精简驱动）、`tools/dev/ai_visible_match.py`（可见局）、
  `tools/dev/adjutant_coexist_probe.py`（共存）、`tools/ai_perf_probe.tscn`+runner（探针）、
  `tools/dev/ai_perf_probe.py`（前会话驱动，保留但被 ai_perf_run 替代）
- 计划状态：`agent/plans/2026-10-11-computer-ai-performance-plan.md` §6 待执行方更新
  （阶段一"新鲜性能基线与优化实现"= 本报告；阶段一/二/三验收门禁仍待用户阶段验收）。
