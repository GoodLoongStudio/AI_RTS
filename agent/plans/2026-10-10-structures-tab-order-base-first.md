# 计划：建筑页顺序调整 —— 主基地（基地）排第一（最上最左）

- 建立：2026-10-10
- 用户口径（原话）：「这个UI的顺序也要调整一下，主基地肯定在最上面最左边」
- 关联历史：`Ra3Sidebar.gd:30-33` 记录过 **2026-09-28 用户要求"矿场放第一个"**；
  本次为**新口径覆盖旧口径**：基地第一，矿场其后。
- **状态：已完成**（改动 + 顺序回归测试 + 可见截图 + 相关回归）；
  闭环报告：`agent/reports/closed-loop/2026-10-10-structures-tab-order-base-first.md`

## 1. 权威来源（只允许一个）

`source/match/hud/ra3/Ra3Sidebar.gd` 的 `const TABS` → `[0] = {"id":"structures"}` 的 `items` 数组**字面顺序**。
依据：
- `_sorted_items_for()`（同文件 :507-515）对 `place == true` 的页签（即建筑页）**直接原样返回、不排序**；
- `ProductionCatalog._build()` 按 `tab_row.items` 顺序构建（`ProductionCatalog.gd:427`），因此目录顺序自动跟随；
- 全仓只有这一处硬编码建筑页顺序（grep `OreRefineryUnit, ` 仅命中该文件）。

## 2. 改动

`Ra3Sidebar.gd` 的 structures 列表：把 `CommandCenterUnit`（基地）从第 2 位提到**第 1 位**，
`OreRefineryUnit`（矿场）顺延到第 2 位；同步更新 `:30-33` 的注释（写明本次用户口径与生效日期），
避免下一个人读到"矿场放第一个"的旧注释又改回去。

改后顺序：**基地 → 矿场 → 车厂 → 机场 → 兵营 → 对地炮 → 对空炮 → 机枪塔**。

**不影响玩法**：点击行为由 `_on_cell_pressed` 按 scene 决定（注释 :33 已说明"只挪格子位置"）。
已确认**没有**按格子序号绑定的建造热键（侧栏只有 `gui_input` → `_on_cell_gui_input`），
也没有测试断言旧的建筑页顺序（`NetInfantrySmokeTest` 用 `any()` 只查"兵营在列表里"；
`BlueprintSwitchSmokeTest` 按**中文名**找格子）。

## 3. 验证

1. 静态：改后 `TABS` 语法/顺序自检（新增回归测试，见下）。
2. 运行时：新增 `tests/automated/StructuresTabOrderSmokeTest`，断言
   ① 建筑页第 1 格是 `command_center`（基地）；
   ② 建筑页**不排序**（`_sorted_items_for` 返回与 `items` 同序）——防止将来有人给它加排序把口径改坏；
   ③ `ProductionCatalog.entries("structures")[0].unit_id == "command_center"`（数据层跟随）。
   登记进 `config/full_regression_suite.json`（category=hud）。
3. 可见截图：窗口化探针切到「建筑」页截图，**亲自打开确认基地在最上最左**。
4. 相关回归：`BlueprintSwitchSmokeTest`（挂载侧栏、按中文名找格子）、`NetInfantrySmokeTest`（读 TABS）。

## 4. 回滚

只改 `Ra3Sidebar.gd` 里两行顺序 + 注释；回滚即把基地/矿场两行换回，并同步删除新增测试与套件登记。
