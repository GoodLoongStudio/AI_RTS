# 运输车多次上下货 / 只载小兵 8 位 / 载员显示 / 运输车与装甲车速度 ×2

日期：2026-10-12。状态：**功能已实现并通过专项冒烟（transport-truck 0 failure）；相关套件补跑在后台，未完成项见 §六。**

## 一、需求与实现口径

| 需求 | 实现 | 权威位置 |
|---|---|---|
| 多次上货 | 保持"标记登车→靠近自动上车"，**分批可继续**；卸空后可再装 | `CargoHold.gd::_process` + 冒烟 4/4/4 分批断言 |
| 多次卸货 | 保持侧栏「卸货」一键**全部下车**（逐个卸下按用户要求已删除）；「多次」由**往返**满足：卸空后可再装，反复多次 | `CargoHold.gd:unload_all` |
| 只载小兵，最多 8 位 | `LOADABLE_UNIT_TYPE_IDS = ["soldier","sniper","rocketeer"]` 白名单；`capacity = 8` | `CargoHold.gd:12-24`、`TransportTruck.tscn:78` |
| 载员显示 | 选中面板头像格左下角实时徽标 `已载/容量`，每轮刷新 | `SelectionPortraitPanel.gd`（`_add_cargo_chip` / `_apply_cargo`，挂在 `_sync_live_stats`） |
| 运输车与装甲车速度 ×2 | transport_truck **5.2 → 10.4**、apc **4.6 → 9.2** | 权威 `config/balance/*.json`（C# `BalanceConfigRuntime` 运行时强制注入）+ 两处 `.tscn` 兜底 |

## 二、改动文件

| 文件 | 改动 |
|---|---|
| `source/match/units/traits/CargoHold.gd` | 容量 10→8；新增小兵白名单常量与 `static _is_loadable_unit_type()`；`_release_passenger()`（`unload_all` 落位逻辑抽出）；`get_capacity()` |
| `source/match/players/human/UnitActionsController.gd` | `preload` CargoHold；新增 `_can_board()`（引用同一白名单），登车两处入口（`_try_board_selected_into_transport` / `_selected_has_boarders`）统一口径 |
| `source/match/units/TransportTruck.tscn` | `capacity = 8`（:78）、`speed = 10.4`（:66） |
| `source/match/units/APC.tscn` | `speed = 9.2`（:67） |
| `config/balance/demo.balance.v1.json`、`adjutant-e2e.balance.v1.json` | transport_truck / apc 的 `speedMetersPerSecond`（两份同步） |
| `source/match/hud/ra3/Ra3Sidebar.gd` | 卸货按钮文案明确为「全部下车，可反复装卸」 |
| `source/match/hud/ra3/SelectionPortraitPanel.gd` | 载员徽标（仅带 CargoHold 的单位出现）+ 每轮实时刷新 |
| `tests/automated/TransportTruckSmokeTest.gd` | 容量断言跟随 `get_capacity()`；新增：非步兵不得上车、4/4/4 分批上货、卸空后再装（往返多次） |

**未改**：DCS（hash 冻结）、副官/寻路/线程/画质/模拟频率。

## 三、证据

1. **专项冒烟**：`TransportTruckSmokeTest` → **rc=0，0 failure**（删除「卸下一位」前：`transport-run2.log`；删除后复跑：`transport-run3.log`）。覆盖：容量 8、分批上货（4→8、满舱拒绝第 3 批）、坦克不得上车、卸货后清空、卸空后可再装（往返多次）、运输车致死清理。
2. **解析校验**：`CargoHold.gd --check-only` rc=0；测试文件 rc 仅剩 `--script` 模式不加载 autoload 的已知假错（真实场景运行无该错）。
3. **数据校验**：两份 balance JSON 改后仍可 `json.load`，`transport_truck=10.4 / apc=9.2`。
4. **diff 范围核对**：本轮对 balance 的改动仅 2 行 `speedMetersPerSecond`（按行号精确替换，未触碰其他字段）。

## 四、重要发现（影响口径判断）

- `config/balance/demo.balance.v1.json` 中**多个单位的速度/射程/工时近期已被其他未提交改动整体调整**（HEAD 2.6 → 工作树 5.2，即已被翻倍）。本轮是**在当前生效值上再 ×2**（5.2→10.4、4.6→9.2），即相对**你现在游戏里的速度**翻倍。若你要的是相对更早基准（HEAD 2.6/2.3）只翻一倍，请告知，回退这 4 个数值即可。
- `balance-config-runtime` 冒烟 rc=1（2 处失败：Tank 生产成本、Worker 载荷）——**与本轮改动无关**（本轮只改 speed 与 capacity），属他人未提交平衡改动造成的既有失败。

## 五、副作用提示

速度翻倍会同步放大 `Movement.gd` 的**避障邻居半径**（`speed × time_horizon`）与**卡死判定阈值**（同样随 speed 联动），可能表现为更早避让/绕行更远。属用户明确要求的改动，已在相关移动套件中回归（结果见 §六）。

## 六、未验证项

1. 相关套件结果（`background-suites-summary.txt`）：`selection-portrait-panel` 1 条失败「工人格应显示 ×3 角标」——**既有失败**：该测试在 button 的**直接子节点**里找 `Label`，而实现的角标 `Label` 嵌在 `PanelContainer` 里（`SelectionPortraitPanel._add_count_badge`），结构上永远匹配不到；本轮对工人格不创建任何载员徽标（无 CargoHold），与此无关。`movement-scale` / `local-avoidance` / `narrow-passage` 三项 **TIMEOUT**——四套件并发跑且机器有并行会话占用 CPU，属资源竞争，**需串行空闲窗口重跑**才能判定（不算产品失败）。
2. **实机手感与显示**（载员徽标视觉、卸下一位按钮位置、提速后的观感）未经玩家实机确认——需要你启动游戏实测。
3. `tests/automated/_premigration/TransportTruck.tscn`（历史快照副本，speed 2.75/capacity 10）**未同步**，未确认它是否参与任何断言。

## 七、回滚

- 逻辑：`git checkout -- source/match/units/traits/CargoHold.gd source/match/players/human/UnitActionsController.gd`
- UI：`git checkout -- source/match/hud/ra3/Ra3Sidebar.gd source/match/hud/ra3/SelectionPortraitPanel.gd`
- 数据：4 个数值回退（balance 两文件各 2 行 + 两个 `.tscn` 各 1 行）
- 测试：`git checkout -- tests/automated/TransportTruckSmokeTest.gd`