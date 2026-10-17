# G2 v7.11.0 战略地貌候选 · 256m

本轮重点：可选完整主河（包含桥下水体）、独立湖泊、出生台地、路线/中部高地、实际寻路。

轮廓更新：不等长崖段、浅凹口和延伸地块；同区域台地与岩体采用相关走向；坡口优先靠凹口并预留展开空间；岩块沿崖脚与河岸成组安排。地面0.6m、台地3.6m，保留3m高差。

几何验收：开放分量严格为1；出生20m净空；有河时主河贯通且具备至少2个有效跨水点；湖泊完整分离；台地至少2个坡道；
出生台地包含出生点；中立台地关联实际路线；每家两组对外主路/备选路线；扩张路程比≤1.3；
邻接争夺路程比≤1.3；最近中立高地入口路程比≤1.7；邻接玩家路程和比≤1.6；障碍12–22%。

PASS仅代表这些几何检查通过，尚未验证单位射程、视野、高地伤害加成或实战胜率。

| Seed | 障碍 | 水系/桥 | 台地（出生/路线/中部） | 扩张比 | 中立高地比 | 邻接路程比 | 候选轮次 | 几何结论 |
|---|---|---|---|---|---|---|---|---|
| 16 | 40.2% | 1 / 6 | 2 / 1 / 0 | 1.005 | 3.191 | 1.383 | 1 | FAIL |

## Seed 16

[地貌总览](seed_16_overview.png) · [路线叠加](seed_16_strategy.png)

- 台地 (180.8, 191.5)：P2 出生保护；3 个坡道。
- 台地 (58.2, 179.5)：P0 出生保护；3 个坡道。
- 台地 (104.4, 213.8)：route，关联 pair_2, pair_3；2 个坡道。

生成记录：
- 第 1 版：plateau_full_pass, plateau_area_pass, plateau_fair_pass, neutral_contest_pass, bridge_width_pass。
- 第 2 版：No complete river corridors satisfy the selected layout and home clearance.。
- 第 3 版：No complete river corridors satisfy the selected layout and home clearance.。
- 第 4 版：No complete river corridors satisfy the selected layout and home clearance.。

主河可选零或一条，湖泊可独立选择零至两个。中部空间不足时允许没有中立中央台地；已有中心出生台地也会占据中部。
数据兼容字段保留，但本轮没有运行 G3/G4，没有将候选自动放行。
