# 闭环报告：建筑页顺序调整 —— 主基地排第一（最上最左）

- 日期：2026-10-10
- 用户口径（原话）：「这个UI的顺序也要调整一下，主基地肯定在最上面最左边」
- 计划：[`agent/plans/2026-10-10-structures-tab-order-base-first.md`](../plans/2026-10-10-structures-tab-order-base-first.md)
- 提示词：[`agent/prompts/2026-10-10-structures-tab-order-base-first.md`](../prompts/2026-10-10-structures-tab-order-base-first.md)
- 状态：**已完成并验证**（代码 + 顺序回归测试 + 可见截图亲自查看 + 相关回归）

## 1. 结论

建筑页第一格现在是 **基地（CommandCenter）**，矿场顺延第二格。
新顺序：**基地 → 矿场 → 车厂 → 机场 → 兵营 → 对地炮 → 对空炮 → 机枪塔**
（前 6 格即玩家一屏所见：第一行 基地/矿场，第二行 车厂/机场，第三行 兵营/对地炮）。

## 2. 权威来源（唯一）

`source/match/hud/ra3/Ra3Sidebar.gd` → `const TABS` → `tabs[0]`（`id == "structures"`）的 `items` **字面顺序**。

- 依据 1：同文件 `_sorted_items_for()`（:507-515）对 `place == true` 的页签（建筑页就是）**直接原样返回、不排序**
  ⇒ 字面顺序 = 显示顺序；
- 依据 2：`ProductionCatalog._build()` 按 `tab_row.items` 顺序构建（`ProductionCatalog.gd:427`）⇒ 数据层自动跟随；
- 依据 3：全仓只有这一处硬编码建筑页顺序（grep `OreRefineryUnit, ` 仅命中该文件）。

## 3. 改动

| 文件 | 改动 |
|---|---|
| `source/match/hud/ra3/Ra3Sidebar.gd` | `structures.items` 里把 `CommandCenterUnit`（基地）提到第 1 位、`OreRefineryUnit`（矿场）顺延第 2 位；并把 :30-35 的注释改成新口径，**明确写出"本条覆盖 2026-09-28 的旧口径（矿场放第一个）"**，防止后人照旧注释改回去 |
| `tests/automated/StructuresTabOrderSmokeTest.gd/.tscn` | **新增**顺序回归测试（见 §4） |
| `config/full_regression_suite.json` | 登记 `structures-tab-order`（category=hud，timeout=90） |

**不影响玩法**：点击行为由 `_on_cell_pressed` 按 scene 决定（原注释即如此说明）。
已确认**没有**按格子序号绑定的建造热键（侧栏只有 `gui_input → _on_cell_gui_input`；
`TraditionalUnitCommandHUD._hotkey()` 是选中单位后的指令面板热键，与建筑页格子顺序无关）。

## 4. 自动化验证（rc=0，0 failure，共 17 条断言全绿）

`tests/automated/StructuresTabOrderSmokeTest`：

| # | 断言 | 实测 |
|---|---|---|
| 1-2 | 第 1 个页签是 `structures`；建筑页 8 格 | ok |
| 3-6 | 第 1 格 = 基地（caption/icon/scene 三项）、第 2 格 = 矿场 | `基地 / 矿场` |
| 7 | 建筑页**不排序**（`_sorted_items_for()` 与字面顺序完全一致） | 显示顺序 = `["command_center","ore_refinery","vehicle_factory","aircraft_factory","barracks","anti_ground_turret","anti_air_turret","machine_gun_turret"]` |
| 8-9 | 数据层跟随：`ProductionCatalog.entries("structures")[0].unit_id == "command_center"` | `unit_id=command_center display_name=基地` |
| 10-12 | 其它页签未被波及（步兵=soldier / 载具=worker / 飞机=drone） | ok |
| 13-14 | **对齐 `NetInfantrySmokeTest` 对 TABS 的判据**：侧栏含步兵页签、建筑页含兵营 | `["structures","infantry","vehicles","aircraft"]` |

第 13-14 条的由来：`NetInfantrySmokeTest` 在清单里标了 `prelaunch_server: true`（需先起服务端），
**单独跑必然失败**（实测：在 Match 启动前就断言失败）；而全量运行器在当前工作区**拒绝启动**
（既存的 130 个"未登记场景"审计不匹配，见 §6）。因此把它与 TABS 有关的两条判据并入本测试守住。

## 5. 可见截图（已亲自打开查看）

探针 `agent/runs/tab-order/_StructuresTabShot.tscn`（窗口化真实渲染，切到「建筑」页）：
- `agent/runs/tab-order/screenshots/01_structures_tab_order.png`（整屏）
- `agent/runs/tab-order/screenshots/01b_crop_grid.png`（网格局部）

探针同时打印侧栏自己记录的格子顺序：
`["基地", "矿场", "车厂", "机场", "兵营", "对地炮", "对空炮", "机枪塔"]`，
并在第一格不是"基地"时判失败（本次 `TAB SHOT completed: 0 failure(s)`）。

我在局部图里看到的：**第一行最左是「基地」(2400)**，其右是「矿场」(900)；第二行 车厂(600)/机场(1200)；
第三行 兵营(600)/对地炮(600) —— 与用户要求一致。

> 过程记录：探针首版把 `sidebar._cells` 当成 Button 调 `get_meta()`（实际元素是 `_make_cell()` 返回的
> **Dictionary**，中文名在 `cell.item.caption`），运行期报错后窗口化进程不退出、看起来"卡住"。
> 已按 `BlueprintSwitchSmokeTest._find_cell()` 的读法修正，并加 60s 看门狗强制退出。
> 该错误只存在于 `agent/runs/` 下的临时探针，不进产品代码。

## 6. 相关回归

| 套件 | 结果 |
|---|---|
| StructuresTabOrderSmokeTest（新） | rc=0，0 failure |
| BlueprintSwitchSmokeTest（挂载真实侧栏、按中文名找「机场」「对空炮」格子） | rc=0，0 failure |
| NetInfantrySmokeTest | **无法在本工作区有效运行**：清单要求 `prelaunch_server`（单跑必失败，失败点是"联机对局应完成加载并出现 Match"）；全量运行器又因既存审计不匹配拒绝启动。其 TABS 判据已由本测试第 13-14 条覆盖 |
| LegacyHudVisibilitySmokeTest | 13 failure —— 本会话早些时候已用 in-repo A/B 证明是**既存红**（改动前后各 13） |

**既存工作区问题（与本改动无关，供参考）**：`tools/run_full_regression.ps1` 在运行前做
"清单场景 vs 磁盘场景"审计，当前磁盘上有 **130 个未登记场景**（114 个 `_*Probe` + 16 个其它），
脚本直接 `throw "Regression manifest scene mismatch; unregistered [...]"` 退出。
我本次新增的 4 个场景（2 个测试 + 2 个探针）**不在**该未登记清单里（测试已登记，探针在 `agent/runs/` 下不被扫描）。

## 7. 未验证 / 范围

- **未跑全量回归**（清单 122 项；原因见 §6 的运行器既存审计问题）。
- 只改了**建筑页**顺序；步兵/载具/飞机页未动（且有断言守着各自第 1 格）。
- **联机客户端未实测**（顺序是本地 UI 常量，客户端读同一份 `TABS`）。
- 未改动任何造价/图标/解锁/放置逻辑。

## 8. 并行工作区风险（已核对）

`Ra3Sidebar.gd` 里**还有其它会话未提交的改动**（例：飞机页注释里的"直升机 → 战斗机"改名），
本次只精确替换了 `structures` 顺序块与文件头注释，**没有触碰**其它行。
回滚只需把那两行换回（基地/矿场互换）并删除本测试与套件登记。
