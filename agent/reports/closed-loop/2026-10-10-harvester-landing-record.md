# 落库记录：矿车「第一次采矿绕道并停下」

- 日期：2026-10-10
- 仓库：`G:\AIRTS\AI_RTS`（HEAD `9a2e6d4`，落库前 dirty 文件 955 个 —— 大部分是其它会话的未提交工作）
- 用户授权：① 落库；② 允许修 `Movement.gd:2609`；③ **不恢复** 923 的 30m 选矿/搜索半径
- 关联报告：`agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour.md`

## 1. 落库时发现：A、B 两处已由并行会话实现

落库前的预检显示补丁里的 `OreRefinery.gd` 部分已不能应用 —— 因为它们**已经被别人改好了**：

| 位置 | 仓库现状（并行会话实现） | 与我的补丁 A/B 的关系 |
|---|---|---|
| `OreRefinery.gd:147` | `miner.call_deferred("request_legacy_start_auto_gather")` | = 我的 **B**（赠车立刻点火自选采集），语义一致 |
| `OreRefinery.gd:411` | `const CLAIMABLE_ACTIONS: Array[String] = []` | = 我的 **A**（接管只认空闲车），语义一致 |
| `OreRefinery.gd:430` | `return action_name in CLAIMABLE_ACTIONS` | 同上 |
| `Movement.gd:2609` | `var who: String = str(_unit.name) if _unit != null else "?"` | 用户授权的那一行**已被他们改好**，我无需再动 |

⇒ 因此实际需要落库的只剩 **patch C**。

## 2. 实际落库内容（patch C）

- 文件：`source/match/units/actions/MovingToUnit.gd`
- 补丁：`agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour-C-only.patch`（+37/−8）
- 命令与结果：
  - `git apply --check` => **rc=0**
  - `git apply` => **rc=0**
  - 落库前 sha `1DDC1C944871` → 落库后 sha **`54869ADBC57D`**
  - 与隔离副本里已验证的版本**逐字节一致**（行尾也是 LF，无差异）
- 内容：采集接近落点改为「以车来向为基准 ±35° 车道 + 落点压进矿半径 + 缓存世界落点」（923 口径）

## 3. 落库后验收（**真实仓库树**，非隔离副本）

脚本 `agent/runs/first-trip-detour-b/run_landing_acceptance.ps1`，日志 `agent/runs/first-trip-detour-b/landing/`。

| 项目 | 结果 |
|---|---|
| 采集链探针（布局 47）`probe_harvest_loop_gen` | **首次交付 8.3s**；`[REFINERY] 指派工人` **0 行**（不再被接管）；SCRIPT_ERROR **0** |
| 3 车同矿探针（布局 47）`_MultiWorkerProbe47` | 三车同拍 `adhere=true`（采样 3）；`assigned=0`（采样 9）；交付 **6 次**；`指派工人` 0 行；SCRIPT_ERROR 0 |
| `OreRefinerySmokeTest` | rc=0，**0 failure** |
| `RefineryFreeMinerSmokeTest` | rc=0，**0 failure** |
| `RuleAiEconomyQuerySmokeTest` | rc=0，**0 failure**（修复前该套件 2/3 红） |
| `WorkerGatherSmokeTest` | rc=1，**2 failure**（既有红，与落库前 A/B 逐条相同，非本次引入） |

同时这也证明：`Movement.gd:2609` 修好后**仓库树可以正常启动并跑真实 Match**（三处探针/套件全部正常收尾）。

## 4. 回滚方式

**只回滚我这次落的 patch C**（A/B 是并行会话的改动，**不要**回滚它们）：

```powershell
cd G:\AIRTS\AI_RTS
git apply -R agent/reports/closed-loop/2026-10-10-harvester-first-trip-detour-C-only.patch
```

回滚后 `MovingToUnit.gd` 的 sha 应回到 `1DDC1C944871`。

## 5. 未做 / 不属于本次

- **未提交任何 git commit**（工作区仍是 900+ 未提交改动，属于各会话的工作）。
- **未恢复 30m 选矿/搜索半径**（用户明确选择不恢复）。
- **移动层"末段停在矿外 4m"仍在**（`agent/plans/2026-10-10-movement-stop-short-plan.md` 已备好夹具与判据）；
  另有一条"资源被放在不可走格上"的姊妹任务（同计划 §6）。
- 多车/玩家采集单、交付拥堵场景的完整 A/B 证据在报告 §11/§15.3。
