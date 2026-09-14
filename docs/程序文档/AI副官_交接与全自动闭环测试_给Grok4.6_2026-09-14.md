# 给 Grok 4.6 的交接与全自动闭环测试提示词

> 把本文件**整体**发给 Grok 4.6（它是实施者；不要只发片段）。
> 项目：`G:\AIRTS\AI_RTS`（Godot 4.7.1 mono + Python 副官）。日期：2026-09-14。
> 上位依据（**冲突时以它们为准**）：
> 1. `docs/项目统一规范.md`
> 2. `docs/程序文档/AI副官_当前执行入口.md`（入口/优先级）
> 3. `docs/程序文档/AI副官_实战能力升级计划_2026-09-14.md`（**U0–U7 + T01–T18 + §7 指标/硬门 + §8 对照**）
> 4. `docs/程序文档/AI副官_DeepSeekV4.1严格执行提示词_2026-09-14.md`（执行纪律：**每局先写测试卡**、运行中每 30 秒偏差检查、**合格前提不成立就判无效验收**、每次失败要改变下次验证依据、进度更新只写四句话）
> 5. `docs/程序文档/AI副官_实战能力升级执行进度_2026-09-14.md`（**唯一进度入口**）

---

> 2026-09-14：本交接保留历史运行命令和工具参考；具体测试节拍、前提核对、偏差提前结束与持续自验，以 DeepSeek V4.1 严格执行提示词第零节和实战升级计划补充条款为准。

## 一、你的身份与硬边界

- 你是**实施开发的助手**，不是替换游戏内模型：运行时仍是本机单模型（MiniCPM5-2B，快/深同一模型）。不引入第二个模型或付费远程服务。
- **不要** commit / push / deploy / 切分支 / reset。工作区可能同时有别人（用户/其他会话）的在途修改：**不动、不回退、不覆盖**。
- **不要**按进程名批量杀进程；只按**端口/命令行**确认属于本次任务后再收（见 §四.6）。
- **不要**用"Accepted 次数 / 任务数 / batch 数 / squad_multi / 单测全绿 / 截图好看"当能力完成证明。
- **不要**靠降低难度取胜：不改单位数值、不扩初始资源、不关迷雾、不降军队上限、不减少画质。

---

## 二、当前状态（截至 2026-09-14，交接时点）

### 2.1 环境事实（**都已核实，别再花时间重新发现**）

| 项 | 事实 |
|---|---|
| 仓库 | `G:\AIRTS\AI_RTS`（**`G:\AIRTS` 本身不是 git 仓库**）；分支 `yyp_test`；本轮开工 HEAD `7af9d180` |
| 未提交 | 70 个文件（属正常：多人协作在工作区推进），`git diff --stat` ≈ 42 files, +5229/−833 |
| .NET | 实测解析 **8.0.425**；`global.json` = `8.0.100 + latestFeature`；规范写 8.0.423 → 差异**如实记录**，不改配置 |
| Godot | `G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\..._console.exe`（`4.7.1.stable.mono`） |
| `G:\AIRTS\AI_RTS_verify` | **失效的 git worktree** —— 不能当干净对照检出 |
| 基线快照 | `G:\AIRTS\output\adjutant_upgrade_20260914\baseline\`（HEAD 副官源码 + `working_tree.patch` 458KB） |
| F01–F04 复现脚本 | `G:\AIRTS\output\adjutant_upgrade_20260914\u0_repro.py`（→ `u0_repro_evidence.json`，含逐文件 sha256） |
| 场景/阈值配置 | `G:\AIRTS\AI_RTS\config\adjutant_upgrade_scenarios.json`（T01–T18 + §7 指标 + 硬门 + 机器基线，**已冻结**） |
| 审查证据 | `G:\AIRTS\output\adjutant_review_20260914\{review.md, audit.py, evidence.json}` |

### 2.2 已完成（**保留，不要重做**）

- **U0**：环境/分支/哈希/快照/场景阈值/F01–F04 重跑结论已写入进度表；
  ⚠ **R0 真机行为基线仍缺失**（工作区脏、无干净检出）——**如实标缺失，不补造**；需要时用"源码快照 + 独立端口"另建检出跑。
- **U1-a / a2（F05 真因）**：无人机 `no_path` 的真因是**空域导航地图不可用**，与寻路算法无关：
  - `Navigation._release_server_owned_navigation_resources()` 会 free 掉空域 map RID；节点复用后
    `region_set_map(region, 失效RID)` 把 region 挂到**默认世界地图**（`region_map_valid=true` 是假象）→
    `map_set_active(true)` 静默无效 → 空域查路恒 `navmesh_unavailable`。
  - 修法：`source/match/AirNavigation.gd` 新增 `_ensure_navigation_map()`（失效即**重建** + 参数 + 挂 region + 激活），
    `_ready()` 与**每次 `bake()` 开头**都调用；诊断行 `NAVDBG air polygons=… rid_valid=… region_on_our_map=… map_active=…`。
  - 另修：`op=adjutant_nav_path` 查询点**必须用该域高度平面**（原实现恒 `y=0`，空域在 `Constants.Match.Air.Y`），
    失败回执带 `domain/plane_y/unit/detail`；观测新增**移动域能力事实** `domain`（air/terrain）。
  - 真机效果：空中不同采样位置 **1 → 67**、`no_path` **608 → 0**、`scout_first_coverage` **0.0 → 1.0**。
- **U1-b（F01）**：`rules_fallback.explore_frontier()` = **探索前沿 + 访问记忆**
  （24m 格；到达→`covered` 换前沿；连续 3 次失败→`unreachable` 退避换目标；记忆有界 128；确定性；情报偏置）。
  接线：`military_waypoint(state=, unit=, ring=)`；行为树经黑板 `state_ref` 传**引用**；
  状态字段 `explore`（dataclass + `GraphStateDict` + 往返 + `summary()` + **`agent_runner` 的 rounds**）。
  F01 的原始复现（无 state、`ring=1..100`）**不再是固定点**。守门 `tests/test_explore_frontier.py`（8 条）。
- **U2 核心（计划 §4.1"遇敌即停"替换）**：`movement.local_force()`
  （接触圈 30m 内 Σ作战单位×血量比；**远方友军不算即时支援**；工人/建筑不计；**类型未知按其可能有武器计入**）
  + `ENGAGE_ADVANTAGE_RATIO=1.2` 才允许压上去打；侦察**优先避战**；`RoutePlan.local_own/local_enemy` 留痕。
  守门 `tests/test_local_engagement.py`（6 条）+ **旧契约测试保留且仍通过**；
  真机（`u2engage`，200s，`model=off`）：`threat_too_high` **65/79/11656 → 0**、放行 **34/48 → 132**、
  攻击回执 **17**、伤害事件 **6**、被迫撤退 **55/33 → {}**。
- 相关单测及实际总数：记录当次结果；不把历史 737 条当固定期望值（截至交接）。

### 2.3 剩余工作（按依赖顺序，**这就是你要做的**）

| 阶段 | 剩余项（要点） | 入口/相关文件 |
|---|---|---|
| U1 收尾 | ① T01 先做 15 秒前置检查；达到 3 个不同前沿即结束探索验收，未达到时最多运行 60 秒并诊断（240 秒只用于另行登记的生命周期问题）；② 侦察**换执行者**（受阻/阵亡转交，`unreachable` 已能标记，"换谁去"未接）；③ T02 受阻恢复（含 navmesh_unavailable 分支） | `graph/rules_fallback.py`（`explore_frontier`/`_pick_probe_unit`）、`graph/movement.py`、`graph/nodes.py` |
| U2 剩余 | ④ F02：**合法目标预筛 + 按距离/威胁排序 + 目标保持**（现在 `_engage_nearest` 取列表第一项）；⑤ F04：**事前权威能力过滤**（现在靠 `unattackable_targets` 30s 黑名单兜底）；⑥ T05/T06：优势打得上 / **劣势减少无谓战损**（用战损与存活验证，不只看"没被拦"）；⑦ T08：多人小队真实共同推进 | `graph/behavior_tree.py`、`graph/rules_fallback.py`、`graph/squads.py`、`graph/nodes.py` |
| U3 | 生命周期闭环（Proposed→…→Completed/Blocked/Failed/Cancelled/Superseded）、等待可退出、事件去重、非阻塞（路径查询/写盘/checkpoint 不得卡住紧急处置）、玩家接管立即让权 | `graph/progress.py`、`graph/arbitration.py`、`graph/nodes.py`、`runtime`/`agent_runner`、`tools/archive_match.py` |
| U4 | `producer_id+item_id` 结算、工人转岗、资源预留、扩张整链（工地→施工→投产→采集） | `graph/rules_fallback.py`、`resource_allocation.py`、`reserves.py`、`placement.py`、`campaign.py` |
| U5 | 真实模型接入与**增益对照**（model=off/timeout/empty/invalid/stale/on 同场景；R1/R2 配对；`provider=real` 不等于调用发生） | `graph/pydantic_agents.py`、`task_patch*.py`、`deploy/agent_runner.py` |
| U6 | 20/40/60 作战单位同负载性能 + B/R0/R1/R2 对照 + 留出地图/种子 | `tools/continuity_report.py`、`tmp_logs/campaign_accept/stress_fps.py` |
| U7 | 用户**正常入口**启动副官、可见发展与战斗过程、回归与交付 | `source/ui/AdjutantButton.gd`、面板端口 24579 |

---

## 三、你的工作循环（每轮都这样走，不要跳过）

1. **写测试卡**（《执行提示词》强制）：本局只验一件事 ——
   `要验证什么 / 预期可见行为 / 控制器与模型模式(model=off 必须标注) / 场景与敌人配置 /
   match 与端口 / 合格前提 / 失败触发条件 / 观察窗口 / 证据位置`。
2. **开局**（见 §四.1），记下 match id/端口。
3. **10–15 秒可见检查**（见 §四.4 截图 + HUD），长局**每 ~30 秒**读一次档案/状态（见 §四.5 监视器）。
4. **判定**：只有"合格前提成立"才计成绩；不成立 → **本局判无效验收**，保存证据、修配置、独立重跑。
5. **失败 → 写最短失败链**：`预期→实际→首个偏离环节→证据→根因假设→最小修复→能区分修复前后的断言`；
   同一失败同条件连续两次 → 必须**增加区分性观测或换假设**，不许盲目重跑长局。
6. **修复 → 回归**（相关单测 + `Godot` headless 冒烟 + 相邻场景），再回到原失败场景。
7. **只更新** `AI副官_实战能力升级执行进度_2026-09-14.md`，每次更新**四句话**：
   在测什么 / 实际画面与权威数据 / 是否符合预期 / 下一步修哪个偏离。

---

## 四、**全自动闭环测试的实操手册**（本仓真实可用的通道）

### 4.1 控制/观测通道：**自研 DCS，不是编辑器 MCP**

> ⚠ **重要前提**：仓库里的 `godot_mcp` / `godot_ai` 是**编辑器级插件**，够不到独立进程里正在跑的对局。
> 真正可用的是自研 **DebugControlServer（DCS）**：**裸 TCP + 一行 JSON**（Godot `put_utf8_string` 会带
> 32 位长度前缀 → 解析时从第一个 `{` 截到换行）。**不要**在这上面白花时间。

| 端口 | 谁 | 用途 |
|---|---|---|
| 24612 | 专用服（headless） | **权威**：路径查询、命令回执、单位真值 |
| 24610 | 可见客户端 | **画面**：`op=screenshot`、玩家视角观测 |
| 24609 | 验收 UDP（`--smokeport`） | 启动器约定 |
| 24579 | 游戏内面板（副官按钮） | U7 用；**正常入口**才探测它，自动化局不要连（历史上被它污染过） |

**起一局（一条命令，自带服务端+客户端+runner+采样+收档）**：

```powershell
cd G:\AIRTS\tmp_logs\campaign_accept
$env:PYTHONUTF8="1"
$env:AIRTS_TEST_BASE="24609"
# ⭐ with_ai 就是"电脑 AI 敌人"开关！探索/发展类场景必须 false（也是用户本地调试约定）
$env:AIRTS_START_EXTRA='{"with_ai": false}'      # 战斗场景才用 true
python short_match.py 30 off <tag>              # <秒数> <model:off|on> <tag>
```

产物：`state_<tag>/runner.out`、`short_<tag>.json`、`shot_<tag>_t*.png`、
档案 `hud\archive_<match>/{rounds,commands,decisions}.jsonl + raw/ + MANIFEST`。

**常用读法（Python，权威口 24612）**：

```python
import json, socket, time
def ask(payload, port=24612, timeout=8.0):
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        s.settimeout(timeout); s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        buf = b""; deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = s.recv(1 << 20)
            if not chunk: break
            buf += chunk
            start = buf.find(b"{"); end = buf.find(b"\n", start)
            if start >= 0 and end > start:
                return json.loads(buf[start:end].decode("utf-8", "replace"))
    raise TimeoutError(payload.get("op"))

ask({"op": "tactical", "as_player": "Player_0"})      # 实体（含 domain=air/terrain、hp、gather/queue/movement）
ask({"op": "adjutant_fast_state"})                    # 10Hz 快照：units/production/visible_enemies/事件
ask({"op": "unit_motion", "unit": "Unit_1"})          # ★逐单位移动诊断：target/committed/reachable/path_points/recovery_mode/velocity
ask({"op": "adjutant_nav_path", "unit": "Unit_1", "from": [x, z], "to": [x2, z2]})
ask({"op": "commands"})                               # 执行层逐条命令（subject/op/status/reason）
ask({"op": "adjutant_leases", "all": True})           # 租约/意图汇总（面板与验收共用的只读视图）
ask({"op": "perf"})                                   # 帧率/画质档/扫描耗时
ask({"op": "rules"})                                  # 规则视图（capabilities → 作战单位口径的唯一来源）
```

**截图（闭环里的"眼睛"）**：

```python
ask({"op": "screenshot", "path": r"G:\AIRTS\tmp_logs\campaign_accept\shot_x_t30.png"}, port=24610)
```

随后**用你的视觉能力直接读这张 PNG**：HUD 上常驻 `xx FPS · 画质 高（90%）`（帧率治理）、
左下 `AI 副官：接管` 按钮、命令信标（`副官：攻击移动 / N 个单位`）。
**判定以权威数据为准，截图只用于"玩家视角是否看得到改善"的辅助证据**（计划 §9 明文）。

### 4.2 历史档案/日志（离线闭环，**不需要起局**）

| 位置 | 是什么 |
|---|---|
| `hud\archive_<match>\rounds.jsonl` | 每轮摘要（含 `units/movement/target_memory/explore/army_cap/nav_revision/quality_tier`…）→ **T01 的 `covered` 就读它** |
| `hud\archive_<match>\commands.jsonl` | ⚠ 同一 `intent_id` 有**两条**（意图级 + 命令级）——算冲突/重复前必须先去重 |
| `hud\archive_<match>\decisions.jsonl` | 决策留痕（`movement_gate`/`same_unit_conflict`/`target_unattackable`/`build_spot_exhausted`…） |
| `state_<tag>\runner.out` | 逐 tick 结构化行（`kind=tick/receipt/decision/…`）→ 连续性分析输入 |
| `tmp_logs\dcs\{server,client}_campaign.out` | 游戏侧日志（`NAVDBG`/Parse Error/EXIT-TRACE 都在这里） |
| `output\adjutant_review_20260914\audit.py` | 审查复现（F01–F04/六份历史档案统计）→ 只读 |

**现成分析工具（沿用，不要另写一份口径）**：

```powershell
python G:\AIRTS\AI_RTS\tools\continuity_report.py <state_x\runner.out> [--gate]     # 连续性六项 + 命令纪律
python G:\AIRTS\tmp_logs\campaign_accept\measure_rejects.py                          # 拒绝率/拒因/重试浪费
python G:\AIRTS\tmp_logs\campaign_accept\measure_conflicts.py                        # 同 tick 同单位双发（真冲突）
python G:\AIRTS\tmp_logs\campaign_accept\iterate.py --tag itN --seconds 30          # 跑一局→取数→落档→对比表
python G:\AIRTS\tmp_logs\campaign_accept\t01_watch.py 170 30                         # ★每 30 秒读档案的一行监视器（T01 用）
python G:\AIRTS\tmp_logs\campaign_accept\probe_u1_path.py 24612                      # 空中/地面路径查询对照（U1 用）
python G:\AIRTS\tmp_logs\campaign_accept\probe_parked.py 24612                       # "停着不动"四种成因归类
python G:\AIRTS\tmp_logs\campaign_accept\probe_compose.py 24612                      # 小队编成（直接调生产代码）
```

### 4.3 Python 侧自检（秒级，别每改一行就跑长局）

```powershell
cd G:\AIRTS\AI_RTS\source
$env:PYTHONPATH="G:\AIRTS\AI_RTS\source"; $env:PYTHONUTF8="1"
python -m unittest discover -s adjutant_coordinator/tests           # 全量（记录本次实际总数；737 条仅为历史基线）
python -m unittest adjutant_coordinator.tests.test_local_engagement  # 单文件
```

Godot 脚本语法（**只报 Parse/Compile Error，`--check-only` 会因为 autoload 名报假错**）：

```powershell
& "G:\AIRTS\godot_mono_471\...\Godot_v4.7.1-stable_mono_win64_console.exe" --headless `
  --path "G:\AIRTS\AI_RTS" --check-only --script "res://source/match/AirNavigation.gd"
```

### 4.4 收尾纪律（**每次都做**）

```powershell
cd G:\AIRTS\tmp_logs\campaign_accept
$env:PYTHONUTF8="1"; python cleanup_all.py            # 收 runner/启动器
# 再按**端口**确认归属后收 Godot（不要按进程名批量杀）：
foreach ($procId in (netstat -ano | Select-String ":24609\s|:24610\s|:24612\s" |
        ForEach-Object { ($_.Line.Trim() -split '\s+')[-1] } | Sort-Object -Unique)) {
  $p = Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue
  if ($p -and ([string]$p.CommandLine) -match '24609|24610|24612') { Stop-Process -Id $procId -Force }
}
netstat -ano | Select-String ":24609\s|:24610\s|:24612\s" | Select-String "LISTENING|UDP"   # 应为空
```

---

## 五、本仓的"坑"清单（**都是实测踩出来的，读一遍能省你几小时**）

1. **`with_ai` = 电脑 AI 敌人开关**（`DebugControlServer._op_start` → `NetSession.start_solo(...)`）。
   探索/发展场景必须 `{"with_ai": false}`；过去所有局都传 `true`，导致"敌人一直在、只是无人机飞不出去没发现"。
2. **空域导航**：`AirNavigation` 的 map RID 会被 teardown free 掉 → 必须 `_ensure_navigation_map()` 自愈；
   查询点必须用**该域高度平面**（空域 `Constants.Match.Air.Y=1.5`）。诊断行 `NAVDBG air …`。
3. **状态字段每轮归零**：LangGraph 在图入口按 `GraphStateDict` 声明过滤；新增**数据类字段**要同时改
   `graph/state.py`（dataclass + `to_dict/from_dict`）与 `graph/graph.py`（通道）；
   **纯动态键**（只 `state["x"] = …` 写的）同样会被丢 → 有静态扫描守门 `tests/test_graph_state_channels.py`。
4. **归档字段要加在 `agent_runner.py`**：`rounds.jsonl` 是 runner 自己攒的（不是 `state.summary()`），
   新指标不进那里 = 复盘看不到（`target_memory`/`explore` 都踩过）。
5. **`nav_revision` 合法值 0**：`int(x or -1)` 会把合法的 0 变成"未知"（全局搜 `or -1` 时逐处判断）。
6. **`commands.jsonl` 的双记录**：同一 `intent_id` 的"意图级 + 命令级"两条**不是冲突**（需按 `intent_id` 去重）。
7. **GDScript `:=` 类型推断**：`var x := 未类型化节点的属性.distance_to(...)` 会**解析失败 = 整个脚本失效**
   （全单位不能动）。必须显式标注：`var x: float = ...`。
8. **不用 `round(x, 2)`**（GDScript 只接受 1 参）—— 用 `_round2()`。
9. **测试夹具要忠实**：`graph_test_helpers.tactical()` 里 `queue/gather/construct` 目前写死为 `False`，
   会让"工厂/工人"在夹具里被当成作战单位（真实 `op=tactical` 是能力字段）。用它做断言时先确认这个前提。
10. **AGV/期望值不要编造**：字段读出来是空 → **先怀疑"它有没有跨轮活下来"**，再怀疑"上游有没有给"。

---

## 六、开始工作的第一组动作（照做）

1. 读 §一 的 5 份上位文档（至少 §三 的循环与 §二 的状态）。
2. `cd G:\AIRTS\AI_RTS\source` 跑相关单测并记录实际总数，不把历史 737 条当固定期望值。
3. 打开进度表，把"U1 收尾 / U2 剩余"里你最想先打的一条写成**测试卡**（§三.1），
   然后按 §四.1 起局、§四.3 做小改自检、§四.2 读档案判定、§三.7 用四句话更新进度。
4. **U5（真实模型）与 U7（用户入口）不要提前宣称通过**；`no_tactics_model` 的档案**不能**当模型能力证据。
5. 遇到真实外部阻塞（服务不可用/环境缺件）→ 记**具体错误与复现命令**，继续做不依赖它的工作，
   该项保持"未验收"，**不编造成功、不无限重复同一失败请求**。

**完成定义**（计划 §10）：核心用户行为、硬门、相关构建和用户入口全部有证据并通过；T01–T18 逐项登记已测/未测和原因，未测项不得伪装成通过。
只看"单测全绿/某一局赢了/计划写完"都**不算**完成。
