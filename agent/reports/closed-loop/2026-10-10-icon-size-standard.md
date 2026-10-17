# 闭环报告：生产卡片图标尺寸规范（建筑/单位观感大小统一）

- 日期：2026-10-10
- 用户口径（原话）：「现在这些UI的建筑的大小你也规范一下，基地这么小，兵营这么大，都不协调」
- 计划：[`agent/plans/2026-10-10-icon-size-standard.md`](../plans/2026-10-10-icon-size-standard.md)
- 提示词：[`agent/prompts/2026-10-10-icon-size-standard.md`](../prompts/2026-10-10-icon-size-standard.md)
- 状态：**已完成并验证**（生成器规范 + 18 张图标重渲 + 规范回归测试 + 拼图/侧栏截图亲自查看）

## 1. 结论

侧边栏生产卡片里所有图标现在由**同一条自动取景规则**渲染：可见内容占画面 **0.813–0.836**
（目标 0.82，极差 **0.023**），内容居中偏差 ≤2px。
改前同一口径实测是 **0.352–1.000（极差 0.648）** —— 「基地这么小、兵营这么大」正是这个来源。

## 2. 改动

| 文件 | 改动 |
|---|---|
| `tests/automated/NewUnitsLineupSmokeTest.gd` | 图标生成改为 `_render_normalized_icon()`：按模型包围盒取景 + 迭代收敛到 `ICON_TARGET_FILL=0.82` + 迭代居中；删掉逐条手调的相机 size/取景高度；roster 补上 `worker`（矿车） |
| `source/match/hud/ra3/icons/*.png` | **重渲 18 张**（17 张 tracked 修改 + `ore_refinery.png` 原本未跟踪） |
| `tests/automated/IconSizeStandardSmokeTest.gd/.tscn` | **新增**尺寸规范回归测试（headless，直接量落盘 PNG） |
| `config/full_regression_suite.json` | 登记 `icon-size-standard`（category=visual，timeout=90） |

**为什么改生成器而不是逐张手修图**：观感大小 = 图内可见内容占比（侧栏用
`TextureRect + STRETCH_KEEP_ASPECT_CENTERED` 显示），而占比只由"模型尺寸 ÷ 相机 size"决定。
旧 roster 是逐条手调（`soldier 0.9` … `command_center 16.0`，注释写着"步兵小、建筑大"），
手调值一多必然飘；换成一条规则后，任何新单位入册都自动落在同一条带上。

## 3. 规范前后对照（同一口径：非透明像素包围盒占 128px 画面的比例）

| 图标 | 改前 | 改后 | | 图标 | 改前 | 改后 |
|---|---|---|---|---|---|---|
| 基地 command_center | **0.563** | **0.813** | | 矿车 worker | 0.852 | 0.820 |
| 矿场 ore_refinery | **1.000** | 0.820 | | 坦克 tank | 0.359 | 0.813 |
| 车厂 vehicle_factory | **0.500** | 0.813 | | 运输车 transport_truck | 0.469 | 0.813 |
| 机场 aircraft_factory | 0.742 | 0.820 | | 装甲车 apc | 0.406 | 0.813 |
| 兵营 barracks | **1.000** | 0.828 | | 重型坦克 heavy_tank | **1.000** | 0.820 |
| 对地炮 anti_ground_turret | **0.352** | 0.828 | | 无人机 drone | 0.250 | 0.820 |
| 对空炮 anti_air_turret | 0.844 | 0.828 | | 战斗机 helicopter | 0.617 | 0.820 |
| 机枪塔 machine_gun_turret | 0.766 | 0.813 | | 步兵 soldier | 0.305 | 0.836 |
| | | | | 狙击兵 sniper | 0.781 | 0.828 |
| | | | | 炮兵 rocketeer | 0.781 | 0.828 |

**极差：0.648 → 0.023**。

## 4. 渲染管线遇到的三个坑（都已修，写进代码注释防复发）

1. **回读滞后**：改完相机立刻 `get_image()` 拿到的是上一帧 ⇒ 出现"空图 0.000"和"量到上一个模型的占比"。
   现在每次改完相机都 `_settle()`（process_frame → frame_post_draw → process_frame），并且**读两次取后者**。
2. **骨骼网格 AABB 失真**：步兵的 `mesh.get_aabb()` 在绑定姿态下退化成 `0.02×0.01×0.02`，
   按它算初值会得到 0.05 的荒谬取景窗，收敛过程中被"线性步进"直接压到 `size≈0.09`，
   渲出三张**深蓝碎片**（拼图里一眼可见）。现在：退化的 AABB 换中性初值 3.0，
   收敛改成"夹紧增益 + 溢出×2 / 空图×0.5"，**永不让 size 塌到 0**，并回退到"最接近目标"的一次取景。
3. **收敛后居中晚一步**：缩放与居中是同一循环里的两步，早退时最易留下偏差（对空炮曾偏 −7px）。
   现在收尾额外做最多 3 次居中迭代。

## 5. 验证

| 项目 | 结果 |
|---|---|
| 生成器自检（18 条 `[ICON] … fill/center/size`） | 全部 **0.813–0.836**，居中 ≤2px，`0 failure(s)` |
| `IconSizeStandardSmokeTest`（新，headless） | **rc=0，0 failure**；极差 **0.023**（上限 0.12） |
| 拼图对照（before/after） | `agent/runs/icon-normalize/montage_before.png` / `montage_final2.png`（已亲自打开：改前兵营/矿场顶满、基地/对地炮偏小、步兵是三块深蓝碎片；改后全部一致，步兵恢复为完整人形） |
| 真实侧边栏截图（建筑页） | `agent/runs/tab-order/screenshots/01b_crop_grid.png`（已亲自打开：基地/矿场/车厂/机场/兵营/对地炮 大小一致，基地在第一行最左） |
| 真实侧边栏截图（载具页） | `agent/runs/healthbar/screenshots/03b_crop_vehicles_panel.png`（矿车/坦克/运输车/装甲车/重型坦克 大小一致） |

**⚠ 一条必须记住的工程坑**：覆盖 PNG 后必须重新导入资源，否则运行时会继续用
`.godot/imported/*.ctex` 旧缓存（我第一次截图与改前**逐字节相同**就是踩了这个）：

```powershell
& Godot_v4.7.1-stable_mono_win64_console.exe --headless --path G:\AIRTS\AI_RTS --import
```

## 6. 未验证 / 残留

- **未跑全量回归**（清单 124 项）：本轮只跑了新增的规范测试；`visual` 类别其余套件在本会话早前已跑过（见另两份报告）。
- `scout.png`（**2026-10-10 已退役**、`TABS` 里 0 引用）保持原样（fill 0.109），只记录不删：
  它是未跟踪文件，删除属于资产清理，需另开任务确认。
- 图标是**离线渲染产物**，本轮只验证了静态 PNG 与侧栏显示；未做不同分辨率/缩放下的人工走查。
- 未改侧栏格子尺寸/布局/造价/解锁逻辑（本轮只动图标资产与生成器）。

## 7. 回滚

```powershell
cd G:\AIRTS\AI_RTS
git checkout -- source/match/hud/ra3/icons        # 16 张 tracked 图标回到改前
git checkout -- tests/automated/NewUnitsLineupSmokeTest.gd
# 删除新增测试与套件登记（tests/automated/IconSizeStandardSmokeTest.*、config 里的 icon-size-standard 条目）
# ore_refinery.png / scout.png 原本就未跟踪，不受影响
```
回滚后需再跑一次 `--import` 让旧图标回到运行时缓存。
