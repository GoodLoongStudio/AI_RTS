# 车厂（生产建筑）受损：不影响生产速度 + 移除误导性的"受损"UI

- 日期：2026-10-10
- 用户口径（原话）：
  1. 「车厂受损会有生产速度影响吗？」（附侧边栏截图：载具页 5 个条目全带 `#受损`）
  2. 「那就不要这种UI显示啊，容易引起误导，我不希望有受损减速这种东西」
- 状态：**已完成并验证**（代码 + 回归测试 + 可见截图亲自查看 + 相邻回归）

## 1. 结论

- **受损不影响生产速度**（实测 59.99 vs 60.04 work/s，差 0.08%）。
- 因此那个 `#受损` 徽标只会误导玩家"受损会减速"，**已整条移除**：
  受损的生产建筑现在与满血一样显示正常状态（`+ 可生产` / `! 资源不足` / `> 生产中`）。

## 2. 改动

| 文件 | 改动 |
|---|---|
| `source/match/hud/production/ProductionCatalog.gd` | ① `STATES` 去掉 `"damaged"`；② 删除"生产建筑受损 → damaged"分支（该分支返回过 `[produce, repair]` 动作与"仅作提示"文案）；③ 删除只被它使用的 `_damage_note()`；④ 文件头/分支处补注释说明口径与原因 |
| `source/match/hud/production/ProductionTheme.gd` | 删除 `STATE_DAMAGED` 常量与 `STATE_TABLE` 里的 `{"glyph":"#","label":"受损"}` 样式 |
| `tests/automated/DamagedProducerSpeedSmokeTest.gd/.tscn` | 新增回归测试（见 §4），断言"速率不变"且"不得再有受损状态" |
| `config/full_regression_suite.json` | 登记 `damaged-producer-speed`（category=production，timeout=120） |

**血量信息没有丢**：生产建筑/单位的 HP 仍在**基地状态条**（`BaseStatusStrip` 的"生命"行）、单位详情与建筑血条上正常展示；
被删掉的只是"生产"语境里那条会被误读成"受损=减速"的状态。

## 3. 速度实测（真实 Match，同一车厂、同一产品）

| 状态 | 采样进度 | 推进速率 | 生产完成时刻 |
|---|---|---|---|
| 满血 32/32 | 6 → 179 work / 2.88s | **59.986 work/s** | 2.95s |
| 受损 9/32（30%） | 7 → 179 work / 2.87s | **60.035 work/s** | 2.93s |
| 差异 | — | **0.08%**（容差 5%） | ~0.7% |

代码口径：产量 = `Unit.production_work_per_tick = maxf(0.1, growth_rate × same_type_rate)`（`Unit.gd:152-155`），
**不含 hp**；C# 每 tick 实时读该值（`GodotProductionProducerRegistry.WorkPerTickOf()`）。

## 4. 回归测试（新增，已登记）

`tests/automated/DamagedProducerSpeedSmokeTest`（rc=0，0 failure），断言：

1. 满血与受损 30% 两种状态下同一产品推进速率一致（±5%）→ 守住"受损不减速"；
2. 受损车厂在队列空时目录状态是 **`ready`**（不再是 `damaged`），且 reason 不再提"受损"；
3. `ProductionCatalog.STATES` 不含 `damaged`；
4. `ProductionTheme.STATE_TABLE` 不含 `damaged`（即那个 `#受损` 徽标样式已不存在）。

实测输出（节选）：
```
[info] 受损后目录返回: state=ready reason=UI 侧粗判可生产。已判定：生产建筑、队列、资源。
ok: 受损车厂不得再返回 damaged 状态（实际 ready）
ok: ProductionCatalog.STATES 不得再包含 damaged（实际 ["ready", ..., "maxed"]）
ok: ProductionTheme.STATE_TABLE 不得再有 damaged 样式（那个 #受损 徽标）
```

## 5. UI 移除的可见核验（已亲自打开查看）

探针 `agent/runs/healthbar/_DamagedBadgeShot.tscn`（窗口化真实渲染）：把车厂打成 30% → 切到侧边栏「载具」页 → 截图。
图：`agent/runs/healthbar/screenshots/03_sidebar_no_damaged_badge.png` 与局部图 `03b_crop_vehicles_panel.png`。

我看到的（对照用户截图）：受损车厂下，**矿车 / 坦克 / 运输车 显示蓝色 `+`（可生产）**、
**装甲车 / 重型坦克 显示 `! 资源不足`**（资金 1200 < 1800/2700，属正常资源判定）；
**五个条目再没有任何 `#受损`**。探针输出 `BADGE SHOT completed: 0 failure(s)`。

## 6. 相邻回归

| 套件 | 结果 |
|---|---|
| DamagedProducerSpeedSmokeTest（新） | rc=0，0 failure |
| ProductionQueueSmokeTest | rc=0，0 failure |
| RefineryFreeMinerSmokeTest | rc=0，0 failure |
| RallyPointSmokeTest | rc=0，0 failure |
| SpawnPointRegression | 无 completion 协议（无 FAIL 行、无 SCRIPT ERROR） |
| VehicleFactoryWorkerProductionSmokeTest | 首跑 1 failure（"矿车 30s 内未部署"）→ **in-repo A/B 两边各跑一次均 0 failure ⇒ 该断言本身抖动**，与本次改动无关 |
| LegacyHudVisibilitySmokeTest | 13 failure，**in-repo A/B 两边一致（13/13）⇒ 既存红** |

A/B 方法：临时把这两个文件切回改动前版本（隔离副本里的旧版，diff 已确认只含本次删除内容），跑完立即恢复并校验 sha
（`ProductionCatalog.gd 797695F18656`、`ProductionTheme.gd 4006C0525690`）。日志在
`agent/runs/healthbar/production-regression/` 与 `agent/runs/healthbar/ab/badge-*.log`。

## 7. 未验证 / 范围

- 只实测了**车厂**；机场/兵营/主基地共用同一条 `production_work_per_tick` 与同一套 `state_of`，结论同样适用，但未逐一实测。
- **联机客户端未实测**：`state_of` 是本地 UI 粗判，客户端读的是同一份目录与本地生产者节点。
- 本轮**未跑全量 120 项回归**，按改动面跑了生产/HUD 相关 8 项。
- 未做"受损减速"规则（用户明确不要）；若将来要做，落点与口径见本文件历史版本（git 未提交，故只在本会话记录里）。

## 8. 回滚

`ProductionCatalog.gd` / `ProductionTheme.gd` 两处删除是独立小块；恢复方式即把 `damaged` 状态与 `_damage_note()` 加回，
并同步把 `DamagedProducerSpeedSmokeTest` 的断言 2/3/4 改回（它现在守的是"不减速 + 无受损状态"）。
