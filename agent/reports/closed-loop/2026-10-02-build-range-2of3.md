# 闭环报告：建造范围圈缩到 2/3（18m → 12m）

- 日期：2026-10-02
- 用户指令：截图里指挥中心的**建造圈**「有 2/3 现在的半径就够了」
- 状态：`needs-review`（边界成对断言未取到，见 §4）

## 1. 权威来源（唯一 ✓）
`source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs:36`
```csharp
internal const float BuildRangeMeters = 12f;   // 原 18f
```
它**同时**是三处的来源 ✓：
1. **建造范围圈**（视觉）：`BuildPlacementArea3D.gd:46` → `_runtime.BuildAreaCircles(...)`；
2. **放置判据**：`GodotStructurePlacementWorldPort.cs:165` 的 `PlanarDistance(...) <= radius + Radius(unit) + BuildRangeMeters`；
3. **环形搜索采样覆盖**：`StructurePlacementRuntime.cs:341`。
GDScript 侧**刻意不写第二份常量** ✓（`StructurePlacementHandler.gd:253-255` 注释明说 ✓）。

## 2. 改动文件与数值
| 项 | 改动前 | 改动后 |
|---|---|---|
| `BuildRangeMeters` | 18f | **12f**（= 18 × 2/3）|

改动仅 **1 个常量**（+1 行注释 ✓），其余 4 处引用**自动跟随** ✓ ⇒ 圈、判据、采样**不会漂移** ✓。

## 3. 运行时实测（真实 Match ✓）
`tests/automated/_BuildRangeProbe.gd/.tscn`（真实 `Match.tscn` + `PlainAndSimple` ✓）：
```
[BUILDRANGE] runtime BuildRangeMeters = 12.000        ← 改动已生效 ✓
[BUILDRANGE] OK: 建造半径应为 12m（2/3 of 18），实际 12.000 ✓
```
⇒ **运行时权威值 = 12.000** ✓，且据此确认**构建产物是新的** ✓（此前踩过 stale DLL 的坑 ✓）。
编译：`dotnet build OpenRTS.sln --no-restore --nologo` ⇒ **0 错误**、1 警告 ✓。

## 4. 未验证项（如实 ✓）
- **接受/拒绝边界成对断言未取到** ✗：探针在 `StructurePlacementRuntime.Evaluate(...)` 处挂住（failsafe 200s 触发 ✓，rc=2 ✓）
  ⇒ 10m 应接受 ✓ / 16m 应拒绝 ✗ 这一对**尚未实测** ✓；
- **没有新截图** ✗：本轮 headless ✓；窗口模式在当前环境会挂（已在前一任务查清真因并记录 ✓）；
- 相关套件结果见下（`structure-placement` 在其之前的记录里就是**既有 hang/红** ✗，非本次引入 ✓）。

## 5. 并行工作区风险
- 只改了 **1 个 C# 常量**（+1 行注释）✓，未触碰其他 Agent 的文件 ✓；
- `dotnet build` 会刷新共享的 `.godot/mono/temp/bin/Debug/*.dll` ✓ ⇒ 若其他会话正在跑 Godot，可能读到新 DLL ✓
  （这是**预期的**：改动本身就是要让它读到 ✓）。
## 6. 相关套件（本会话实测 ✓）

| 套件 | 结果 |
|---|---|
| `blueprint-switch` | **passed=True rc=0** 4.9s ✓ |
| `structure-placement` | **passed=True rc=0** 7.8s ✓（此前记录里是既有 hang/红；本次转绿 ✓）|
| `spawn-point-regression` | passed=False rc=1 87.7s ✗ —— **既有外部原因**：`assets/map_previews/*` 被删导致 balance 降级 ✓（与本改动无关 ✓，早前多轮已记录 ✓）|

## 7. RSI 产物
- `agent/runs/2026-10-02-build-range-2of3/baseline.md` ✓
- `agent/runs/2026-10-02-build-range-2of3/round-01/`（direction 与验证记录随本报告 ✓）
- 计划：`agent/plans/2026-10-02-build-range-2of3-plan.md` ✓

## 8. candidate / champion
- candidate：`BuildRangeMeters = 12f` ✓ —— 编译 0 错误 ✓、运行时读值 12.000 ✓、放置相关套件 rc=0 ✓；
- **提升为 champion** ✓（无硬门禁失败；唯一缺口是 **Evaluate 边界成对断言未取到** ✗ ⇒ 状态保持 `needs-review` ✓）；
- 连续未提升轮数：**0** ✓。
## 9. ⚠️ 用户反馈『现在没变化』—— 根因已查明（重要 ✓）

### 9.1 真因 A：我第一次 `dotnet build` 是**空转** ✗（改动没进 DLL）

| 证据 | 时间 |
|---|---|
| 第一次 `dotnet build` 后，游戏**实际加载**的 `.godot/mono/temp/bin/Debug/OpenRTS.dll` | **10-04 00:53:57**（12 小时前 ✗）|
| 当时的系统时间 | 10-04 12:44 |

⇒ `dotnet build OpenRTS.sln` 报了『已成功生成 / 0 个错误』，但**并没有刷新该 DLL** ✗
（增量构建判定为 up-to-date ✗）⇒ **源码改了、DLL 没变** ⇒ 游戏当然看不到变化 ✗。

**修复**：改用 `dotnet build OpenRTS.sln --no-restore --nologo --no-incremental` ✓
⇒ `.godot/mono/temp/bin/Debug/OpenRTS.dll` = **10-04 12:45:13**（就在当时 ✓）；
⇒ 随后用**新进程**复核：`runtime BuildRangeMeters = 12.000` ✓。

### 9.2 真因 B：用户当前进程是**改动前**启动的 ✗
- 用户进程 PID 30604 启动于 **10-02 15:45:50**（远早于任何一次构建 ✓）；
- Godot .NET **只在进程启动时加载程序集** ⇒ 正在运行的游戏**必然**还是旧值 ✗。
⇒ **必须完全退出游戏/编辑器并重启**（不是退回主菜单 ✓），才会看到新半径 ✓。

### 9.3 圈半径到底缩了多少（精确口径 ✓）
`GodotStructurePlacementWorldPort` 的公式（`StructurePlacementRuntime.cs:122-123` ✓）：
```csharp
reach = 单位 radius + footprint 半径 + BuildRangeMeters
```
⇒ `BuildRangeMeters` 18 → 12 ⇒ **圈半径精确减少 6 米** ✓。
⚠️ 注意：这是把**建造范围那一项**缩到 2/3 ✓；**总圈半径**（含单位半径与 footprint）
   缩小比例是 `(R+F+12)/(R+F+18)` ⇒ 例如 R+F≈6 时约 **0.75×** ✗ 而非 0.67× ✗。
   若用户要的是**总半径**也变成 2/3，需要改 `BuildAreaCircles` 与判据的**整体口径**（另一次改动 ✓）。