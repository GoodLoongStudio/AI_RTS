# 交接提示词：问题 A —— 密对向交叉的"流交互"（movement-scale 吞吐）

> 把本文件整份粘给另一个会话即可。它**自包含**，不需要本会话的任何上下文。
> 与"另一个会话（世界米制归一化）"并行工作，写入范围见 §6，务必遵守。

## 1. 你是谁 / 在维护什么

你在维护 `G:\AIRTS\AI_RTS`（Godot 4.7.1 .NET：C# + GDScript 混合，headless 回归 + 可见单机）。
你的任务是一个**独立的性能/行为课题**，不依赖别人正在做的重构。

## 2. 已完成的诊断（**请勿重复**，直接从这里起步）

场景：`tests/automated/MovementScaleSmokeTest.gd` 与 `tests/automated/_MovementScaleDiag.gd`
（200 个单位，14 列 × 6m 间距编队，起点网格 → 镜像终点网格，净位移约 174m；无遮挡平地）

| 实验 | 结果 |
|---|---|
| **对向交叉**（基线） | 139.9s / 160.0s（两次运行，波动约 14%），到达率 **1.000**（无永久卡死） |
| **同向平移**（仅改目的地方向） | **19.9s** ⇒ 交叉比对向慢约 **7 倍** |
| 自由行进地板（1 个单位同路线） | 126m 用 40.0s（≈3.15 m/s）⇒ 交叉的"拥堵系数" 2.5–2.9× |

**已逐一排除（都做过 A/B，别再试）**：
脱困阈值（`STALL_* ≈1.15m`）、停滞滞回窗口 1→3、避让 horizon 3.0→5.5、**关闭 RVO**（永不收敛，202s）、
恢复预算 8→32（169.4s）、carve/几何、CPU（帧时间 8.7ms 未饱和）。
**"分批/错峰下令"已证伪**：拆 4 批 −14%（120.0s，最好）、10 批 ±0%、**20 批 +57%（220.0s，更糟）**
—— 因为相遇窗口被拉长。⇒ 代价来自**对向车流相互作用本身**，不是下令时机。

**当前夹具预算**已被重估为 `MAX_FRAMES_PER_SCALE = 10800`（180s，= 最坏实测 160s × 1.12，推导写在文件注释里，
含 git 证据：提交 `e4bd9ac` 把起终点改成 174m 却沿用 42m 时代的 90s 预算）。
⇒ **套件现在是绿的**；本任务要解决的是**设计层问题**，不是让它变绿。

## 3. 你的目标

在**不放松任何尺寸口径、不掩盖失败、不把参数调参当解法**的前提下：

1. **量化**至少两种"流交互"方案对交叉吞吐的影响，各给出 A/B 数字；
2. （可选）把最优方案实现成**默认关闭的开关**（不许改默认手感），或给出"结论：不值得做"的定量论证；
3. 目标量级：让 200 单位对向交叉从 ~140s 降到 **≤60s**（同向 19.9s 的 3 倍内）；达不到就如实写清瓶颈。

## 4. 候选方案（择一或组合，每个都要 A/B）

1. **右侧通行偏置**：对向相遇时给一个横向偏置（车道化）。经典做法：按"相对速度方向"给切向分量。
2. **让行优先权**：一侧先行（按队伍/id/距离场），另一侧减速等待成形。
3. **全局绕行**：用流场/距离场把两股流分配到不同绕行半平面。
4. ~~分批/错峰~~：**已证伪，不要重做**。

## 5. 验证协议（照做即可复现）

~~~powershell
$godot = 'G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'

# 单因素度量（探针已有开关：SAME_DIRECTION / DISABLE_AVOIDANCE / MS_STAGGER / MS_STAGGER_INTERVAL / MS_SCALE）
& $godot --headless --path . res://tests/automated/_MovementScaleDiag.tscn --quit-after 60000 *> tmp_logs\diag.log
Select-String -Path tmp_logs\diag.log -Pattern '\[DIAG\]' | ForEach-Object { $_.Line }

# 官方夹具
python tools/run_targeted_godot_tests.py --godot $godot --ids movement-scale

# 并行跑回归（**新工具，比顺序快 2.7×**；时序敏感套件默认走串行车道）
python tools/run_parallel_suites.py --godot $godot --jobs 10 --ids local-avoidance,navigation-stability,movement-recovery,multi-unit-command,entity-force-move,movement-scale,size-unification-regression
~~~

每改一次必须跑：headless 度量 → 上面这批回归（rc 必须 0）→ 记录 A/B 数字。

## 6. 写入范围（与并行会话隔离，务必遵守）

- ✅ 你可改：`source/match/units/traits/Movement.gd`、`tests/automated/_MovementScaleDiag.gd`、
  `tests/automated/MovementScaleSmokeTest.gd`，以及你新增的 `tests/automated/_Flow*.gd/.tscn`
- ⛔ **不要改**（另一个会话正在做世界米制/根缩放归一化）：
  `source/match/units/*.tscn`（19 个场景）、`source/match/Match.gd`、
  `source/match/players/human/StructurePlacementHandler.gd`、
  `source/match/units/traits/MovementObstacle.gd`、`source/match/utils/UnitMovementUtils.gd`、
  `source/csharp/GodotAdapter/Construction/*`
- ⛔ **不要开可见单机**（会抢 9090 / 24579 端口，与另一会话冲突）。需要可见验证时写进交付物留给对方。

## 7. 环境与坑

- Godot：`G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`（Mono/console 版）
- 改 C# 后必须 `dotnet build OpenRTS.sln --no-restore`，并用**新进程**复验
- headless 启动建议设 `AIRTS_INSTANCE_DIR=""`（否则实例登记会按"严格模式"在抢不到调试口时自退）
- 并行跑多个 headless 时端口用 `--quit-after` + 探针自退即可，别用可见窗口
- 机器：12 核 / 24 线程 / 32GB，jobs=10 没问题

## 8. 交付物

1. `docs/问题A_对向交叉流交互_结论.md`：候选方案 + **A/B 表** + 可复现命令 + 明确"未验证"项
2. 若实现了开关：说明默认值、如何开启、对 14 套验收回归的影响（rc 必须 0）
3. 每轮简报：改了什么 / A/B 数字 / 回归 rc / 下一步
