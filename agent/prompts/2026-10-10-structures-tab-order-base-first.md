# 提示词：建筑页顺序调整（主基地排第一）

## 目标（用户原话）
「这个UI的顺序也要调整一下，主基地肯定在最上面最左边」

即：侧边栏 **建筑** 页的第 1 格必须是 **基地（CommandCenter）**，其余保持原有相对顺序。

## 权威来源（唯一）
`source/match/hud/ra3/Ra3Sidebar.gd` → `const TABS` → `TABS[0]`（`id == "structures"`）的 `items` 字面顺序。
建筑页是 `place == true` 页签，`_sorted_items_for()` 对它**不排序**，所以字面顺序 = 显示顺序；
`ProductionCatalog` 也按该数组顺序构建条目。

## 步骤
1. 读 `Ra3Sidebar.gd` 的 `TABS` 与 `_sorted_items_for()` / `_make_cell()`，确认没有二次排序。
2. 把 `{"scene": CommandCenterUnit, "caption": "基地", "icon": "command_center"}` 移到 items 第 1 位，
   `OreRefineryUnit`（矿场）顺延第 2 位。
3. 更新 `:30-33` 的注释：写明 2026-10-10 用户口径"基地在最上最左"，并保留"矿场是经济核心"的历史说明，
   避免旧注释"矿场放第一个"导致后人改回。
4. 不改点击行为、不改造价/图标/解锁逻辑。

## 验证（缺一不可）
1. 新增 `tests/automated/StructuresTabOrderSmokeTest.gd/.tscn`：
   - 建筑页 items[0] 是 `command_center`（基地）；
   - `_sorted_items_for(structures_tab)` 与 `items` 同序（建筑页不排序）；
   - `ProductionCatalog.entries("structures")[0].unit_id == "command_center"`。
   并登记进 `config/full_regression_suite.json`。
2. 窗口化截图：切到「建筑」页，`agent/runs/` 下落图 → **打开图片确认基地在最上最左**。
3. 回归：`BlueprintSwitchSmokeTest`、`NetInfantrySmokeTest`。

## 命令参考
```powershell
$exe='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
$env:GODOT_BRIDGE_PORT='10600'
& $exe --headless --path G:\AIRTS\AI_RTS --quit-after 12000 res://tests/automated/StructuresTabOrderSmokeTest.tscn
```

## 禁止
- 不要为了让旧断言通过而改断言（本任务没有旧顺序断言；若发现，先判定"判据过期"再改并说明）。
- 不要动其它页签（步兵/载具/飞机）的顺序。
- 不要覆盖其他 Agent 的未提交工作。
