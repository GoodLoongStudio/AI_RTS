# 落库清单：矿车「第一次采矿绕道并停下」修复 A/B/C

- 补丁：`agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.patch`
  （**2 个文件**：`OreRefinery.gd` +17/−1、`MovingToUnit.gd` +37/−8）
- 关联报告：`agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.md`（§3 修复、§4 验证、§7/§13 回归、§15 语义对照）
- 前置：**需要用户明确同意**（工作区有其他人未提交的改动；且 `Movement.gd` 当前无法解析）

## ⚠️ 三条硬约束

1. **回滚只能用 `git apply -R <patch>`，绝不能用 `git checkout -- <file>`**：
   `source/match/units/OreRefinery.gd`、`source/match/units/actions/MovingToUnit.gd`
   里含其他人**未提交**的改动，checkout 会把他们的工作一起抹掉。
2. **不要顺手提交**别人的文件；只落本补丁的 hunk（`git apply --check` 先验）。
3. `Movement.gd:2609` 是他人 WIP 的非法行；改它需单独征得同意（等价改法见第 2 步）。

## 步骤

### 0. 落库前快照（只读，留证）
```powershell
cd G:\AIRTS\AI_RTS
git status --porcelain=v1 | Measure-Object | Select-Object -ExpandProperty Count   # 记下改动数
git stash list                                                                     # 确认没有别人的 stash 会被影响
git diff --stat -- source/match/units/OreRefinery.gd source/match/units/actions/MovingToUnit.gd
```

### 1. 防漂移自检（一条命令，必须先 PASS）
```powershell
pwsh -File G:\AIRTS\AI_RTS\agent\runs\first-trip-detour-b\check_patch_drift.ps1
```
- 期望结尾：`可落库：按 agent/checklists/… 执行（回滚用 git apply -R）。`
- 该脚本会做四件事：`git apply --check`；逐文件打印仓库/隔离副本的 sha 与 +/− 行数；
  **把补丁真应用到临时副本再与隔离副本逐字节比**（忽略行尾差异，因为本仓库 `core.autocrlf=true`，
  而 `.gitattributes` 规定 `*.gd eol=lf`）；最后报告 `Movement.gd:2609` 阻塞是否仍在。
- 若报 FAIL：说明相关文件被并行改动覆盖，**先对账、不要强推**。

### 2. 解除工程无法启动（需用户同意）
`source/match/units/traits/Movement.gd:2609`
```gdscript
-		var who := _unit.name if _unit != null else "?"
+		var who: String = str(_unit.name) if _unit != null else "?"
```
（等价改法，只改类型标注；**不属于**本补丁的一部分。）

### 3. 落库
```powershell
git apply "agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.patch"
git diff --stat -- source/match/units/OreRefinery.gd source/match/units/actions/MovingToUnit.gd
# 期望：OreRefinery.gd +17/-1 左右；MovingToUnit.gd +37/-8 左右
```

### 4. 运行时验收（真实 Match，仓库树）
```powershell
$godot='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
# ① 采集链：期望 t≈3s 开始采集、首次交付 ≈8.3s、采集期间不出现 `[REFINERY] 指派工人`
& $godot --headless --path G:\AIRTS\AI_RTS --quit-after 12000 res://tools/probe_harvest_loop_gen.tscn
# ② 多车/玩家采集单：期望 assigned=0、两车 adhere=true 且 cargo>0（本探针在 agent/runs，非持久目录，若已清理可跳过）
# ③ 贴矿夹具：布局 47 期望 dOre<=3.06 并采集；布局 36 仍会失败（移动层缺陷，见 plans/2026-10-10-movement-stop-short-plan.md）
$env:DSH_PROBE_MAP='47'
& $godot --headless --path G:\AIRTS\AI_RTS --quit-after 5000 res://agent/runs/first-trip-detour-b/_StopShortProbe.tscn
```

### 5. 回归（隔离副本已验证的 10 个套件，期望值见报告 §7/§13.1）
```powershell
& $godot --headless --path G:\AIRTS\AI_RTS --quit-after 12000 res://tests/automated/OreRefinerySmokeTest.tscn          # 期望 0 failure
& $godot --headless --path G:\AIRTS\AI_RTS --quit-after 12000 res://tests/automated/RefineryFreeMinerSmokeTest.tscn    # 期望 0 failure
& $godot --headless --path G:\AIRTS\AI_RTS --quit-after 12000 res://tests/automated/WorkerGatherSmokeTest.tscn         # 期望 2 failure（既有红，逐条相同）
& $godot --headless --path G:\AIRTS\AI_RTS --quit-after 12000 res://tests/automated/RuleAiEconomyQuerySmokeTest.tscn   # 期望 0 failure（修复前 2/3 红）
```
其余：`ProductionQueueSmokeTest`、`RallyPointSmokeTest`、`WorkerEngagementPolicySmokeTest`、
`VehicleFactoryWorkerProductionSmokeTest`、`WorkerDeliveryRefineryOnlyTest`、`EconomyAccountSmokeTest`（2 failure 既有红）。
优先用仓库 runner：`python tools/run_targeted_godot_tests.py --godot $godot --ids ore-refinery,refinery-free-miner,worker-gather,rule-ai-economy-query`。

### 6. 回滚（若验收不通过）
```powershell
git apply -R "agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.patch"
```

### 7. 记录
把第 4/5 步的实际数字补进报告（或在 `agent/reports/closed-loop/` 新建一份落库记录），
并说明：改动文件、前后数值、rc、未验证项、是否有并行工作区风险。
