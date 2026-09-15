# G4 大湖：小地图、战争迷雾、坡面三角面 Implementation Plan

## Overview
用户实机截图：近景坡面是米色三角折纸，侧栏没有可用小地图，战争迷雾也看不见。上一轮只改了贴图导入和镜头，没有修这三处运行时契约。

## Current State Analysis
- 256 图高度场已是 513²。`GeneratedTerrain._build` 用 `stride=2 if size>=513`，又抽成 257²，坡面约 1m 一块三角面。
- 小地图 FogOfWarMask 画在 `MinimapViewport` 里，再采样 `FogOfWar/CombinedViewport`。子视口套子视口的 ViewportTexture 在 Godot 4 里经常是全黑，预览图被黑遮罩盖死。
- 上次视觉脚本进局后执行了 `op=fog enabled=false`，主画面迷雾被关；评图默认还是 `Visibility.FULL`。
- 近景地面仍以 111m 一张沙图为主，`sample_tiled` 只混 22%，坡面光照把网格边亮出来。

## Implementation Strategy
1. 513² 源场不再二次抽稀；1025² 才 stride=2。
2. 把 FogOfWarMask 挪到小地图 TextureRect 上（主树 2D），开雾后再绑 CombinedViewport。
3. `--play-map` 默认 PER_PLAYER 迷雾；`--no-fog` 才关。
4. 近景提高世界米平铺沙地权重。
5. 重开带迷雾的一局，截小地图/迷雾/坡面，再让副官打掉电脑。

## Implementation Steps
1. 本计划文档
2. GeneratedTerrain 抽稀门槛
3. Minimap 遮罩换父 + 延迟重绑
4. Main 评图默认开雾
5. showcase_land 近景贴图
6. 活局截图 + 副官消灭电脑

## Timeline
改完立刻重开 G4 大湖；旧对局看不到热改。

## Risk Assessment
- 513² 网格约 26 万顶点，3080 Ti 上可接受；物理碰撞仍然关闭。
- 小地图遮罩换父后要用正方形槽对齐，避免拉伸。
- 迷雾下攻击必须先侦察或走 attack_move。

## Success Criteria
- 进局侧栏小地图能看见湖/台地预览，未开雾为黑、出生点开雾
- 主画面离开视野圈变黑，不是整图敞亮
- 近景坡面不再是一米一块米色折纸
- 工人能移动、能放下建筑；副官能消灭电脑敌人

## Progress Tracking
- ✅ 计划
- ✅ 网格抽稀
- ✅ 小地图遮罩
- ✅ 评图默认开雾
- ✅ 近景贴图
- ✓ 活局：迷雾有效、工人移动/采集、兵营车厂已建、坦克列队移动
- ⏳ 坦克下台地绕河消灭电脑（直线会掉进河谷）

## Related Files
- `AI_RTS/source/match/maps/generated/GeneratedTerrain.gd`
- `AI_RTS/source/match/hud/Minimap.gd`
- `AI_RTS/source/match/FogOfWar.gd`
- `AI_RTS/source/Main.gd`
- `AI_RTS/source/match/maps/generated/showcase_land.gdshader`
- `AI_RTS/tools/verify_g4_large_lake_playable.gd`
