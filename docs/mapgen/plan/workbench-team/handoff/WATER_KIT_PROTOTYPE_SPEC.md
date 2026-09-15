# 河道与湖泊 Kit 原型规格

## 目标

为现有 G2 水体建立可独立验收的 G4 视觉组件。组件只读取水体边界、桥锚点和高度数据，不修改 `water_footprint`、`blocking`、`passable`、桥位或导航语义。

## Kit 类别

| kit_id | 部件角色 |
| --- | --- |
| `river_bank` | straight、inner_curve、outer_curve、shallow_bank、bank_corner、bridge_head |
| `lake_shore` | shallow_bank、rock_shore、shore_platform、resource_edge |
| `bridge_4006_single_tier` | deck_middle、end_cap、rail、rail_pillar、support |
| `water_connector` | bridge_head、ramp_foot、shore_rubble、controlled_vegetation |

每个实例记录 `kit_id`、`piece_role`、`source_asset`、`anchor`、`transform`、`scale` 和依赖哈希。尺寸只能在资产清单允许范围内适配，超限即失败。

## 结构约束

- 河岸和湖岸只包裹独立水体边界；湖泊不能被转成可走地面。
- 水面和水床保持连续；桥面是唯一跨水通行结构。
- 不使用隐藏地面、缩小水域或额外碰撞体制造连通。
- 岸坡复用 `g4_terrain.py` 的连续高度规则，桥面保持地面高度。

## 固定原型样例

1. 单河 + 桥：验证河流连通、桥头两端和桥下连续水床。
2. 单湖 + 湖岸：验证湖泊面积、完整边界和不可通行水体。
3. 河湖组合：验证独立水体、桥与湖岸不互相截断。
4. 边界失败样例：记录资产尺寸或空间不足，必须如实失败。

原型验收通过后，才接入 `g4_export.py` 的生产导出和后续 `AI_RTS` 高度/导航适配。
