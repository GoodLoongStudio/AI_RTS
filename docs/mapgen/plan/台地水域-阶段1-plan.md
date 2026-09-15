# 台地 + 水域 · 阶段1（生成器侧）规格 — G2 v5

> 用户 2026-09-05 拍板：**生成器先行**（本阶段不碰 AI_RTS）、**水仅桥/渡口**（不做两栖）。
> 本阶段只在 `RTS_Map_Tool` 内把"高程 + 水 + 坡道 + 桥"做进格网并自顶向下验证；
> 真 3D + 导航接入属**阶段2**（另开计划，改 AI_RTS，见 §7）。
> 上游：G2 v4.0.0（开阔+连续隔墙单桥+河+台地块+岩簇，blob 蚀刻口）。本规格将其升为 **G2 v5.0.0**。

---

## 1. 目标观感（top-down）

- **台地**：一片抬升区（着色比地面亮/带高程纹），四周是**悬崖环**（深色），1–2 个**坡道缺口**（窄通道）连通地面与台地顶；顶面**可行走**。
- **水域**：连续水带/水块（蓝），地面不可过；**桥**= 跨水的窄通行带（地面高度），1–2 座；不再用"把水挖断成陆颈"的旧渡口。
- 其余维持 v4 红线：开阔主导、连贯不纸屑、无布尔感、kit 风格、分布均衡。

## 2. 格网通道变更（contract.CHANNEL_DTYPES）

新增 `("height", "f4")`（米）。层高对齐旧契约：
- 地面 `ground_level = 0.6`
- 台地顶 `plateau_level = 3.6`（差 3.0）
- 水 `water_level = -2.4`
- 桥 = `ground_level`（跨水）
- 坡道 = 地面→台地顶之间的过渡格（阶段1 记 `mid = (0.6+3.6)/2 = 2.1`，阶段2 再按坡向插值）

`blocking`（地面 2D 可走性）新语义：
| 区域 | blocking | height |
|---|---|---|
| 地面 | 0 | 0.6 |
| 水 | 1 | -2.4 |
| 桥 | 0 | 0.6 |
| 台地顶（interior） | 0 | 3.6 |
| 悬崖环（ring） | 1 | 3.6 |
| 坡道（ramp） | 0 | 2.1 |
| 隔墙/岩簇/废墟（wall/rock/ruin/debris） | 1 | 0.6 |

> 关键变化：台地从"整块 blocking"改为 **ring blocking + interior 可走 + ramp 连通**；
> 水从"terrain=5 的 blocking 块（挖断成陆颈）"改为 **连续水 + 桥通行**。

## 3. 生成规则（g2_layout.py）

### 3.1 台地（改 build_plateaus）
- region `P` = 现有 proto_blob（kit 签名，象限定向放满 3 个）。
- `ring = P & ~erode(P, 2)`（悬崖环厚 ~2 格）。
- `ramps` = 1–2 个窄 proto_blob（宽 `plateau_ramp_width`≈6）蚀穿 ring（位置种子定，避开彼此）。
- `interior = P & ~ring`。
- 返回 `{region:P, ring, ramps, interior, center}`；`gaps` 字段废弃。

### 3.2 水 + 桥（改 build_rivers）
- 水 mask = 连续带（**删除 ford 挖断**）；pair_0 隔墙仍为 water 语义。
- `bridges` = 1–2 条跨水窄带：在水带某弧长处，沿水带法向（pb）放一条宽 `bridge_width`≈6、长度=水宽+4 的条带；blocking=0、height=0.6。
- 返回 `{mask:water, bridges, bridge_centers}`；`gaps/gap_centers` 由 bridges 取代。

### 3.3 blocking / height 装配（build_blocking + run_one）
- blocking = 隔墙(非water) ∪ cover ∪ ring ∪ water；
- blocking[bridges]=0；blocking[ramps]=0；（interior 本就不在 blocking）。
- height 按 §2 表逐区赋值；默认 ground_level。
- `protected`（强制开阔/避让）改用 bridges/ramps 中心取代旧 ford gap 中心。

### 3.4 连通性验收（heightfield 地面可达）
- 在 `passable = (blocking==0)` 上：4 出生 + 4 扩张 + 各台地 interior 代表点 + 桥两端 必须同一连通分量（坡道/桥把台地顶与水面两侧接入）。
- 坡约束（阶段2 用，阶段1 记录）：坡道坡向长度 ≥ (3.6-0.6)/tan30° ≈ 5.2m、宽 ≥5m；`agent_max_climb=0` 要求坡连续无台阶；烘焙 AABB Y≤5（3.6 满足）。

## 4. 可视化（viz/plots_g2 + review）
- 底图按 height/terrain 着色：水=蓝、台地顶=亮褐/带高程纹、悬崖环=深、桥=地面色加桥纹、坡道=过渡色、地面=米白。
- 图例加：water / plateau-top / cliff / ramp / bridge。
- 继续遵守图例面板规范与"文字只在边框"。

## 5. 参数（contract.G2_DEFAULTS 新增）
```
"water_level": -2.4, "ground_level": 0.6, "plateau_level": 3.6,
"plateau_ramp_count": (1, 2), "plateau_ramp_width": 6.0,
"bridge_count": (1, 2), "bridge_width": 6.0,
```
`ALGO_VERSION["G2"] = "5.0.0"`（结构性重做，升主版本；G3/G4 需重跑）。

## 6. 验收（阶段1 完成标准）
- 三 seed（16/35/61）G2 v5 全 PASS；`pytest` 绿（更新 test_g2 以新语义：interior 可走、水 blocking 除桥、ring blocking 除坡道）。
- review 图：台地=亮顶+深色环+坡道缺口；水=连续蓝+桥；无布尔感、无纸屑、开阔主导（障碍占比含 ring+water+wall+cover，建议验收区间 12–22%）。
- 连通性 §3.4 全通。
- 方案 Progress Tracking 更新；汇报含逐张看图自检声明。

## 7. 阶段2 预告（不在本阶段做）
- G4 导出真 3D：台地/坡道用 ArrayMesh 高度场或"台地盒+坡道楔"；水面用水平面；碰撞只给地面层（水对地面 blocking、对空不挡）；桥=地面高度通行盒。
- AI_RTS 改：ground-snap 改高度查询、点击射线对高度场、小地图高程/水着色、`Air.Y` 改相对地面、navmesh 坡道烘焙（≤30°、climb=0 连续坡）。
- 允许改 AI_RTS 范围同接手提示词 §3 步骤3（maps/generated、assets/scifi-worlds、MatchConstants MAPS）+ 导航/高度相关最小集（需单列清单审批）。
