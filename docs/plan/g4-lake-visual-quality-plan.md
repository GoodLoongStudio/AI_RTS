# G4 大湖画面：别再全黑、材质要能看 Implementation Plan

## Overview
活局截图主画面近乎全黑，小地图只有出生点一小块开雾。玩家要的是能看见地形、湖水和 Synty 模型细节，不是 59 FPS 的黑幕或米色塑料板。

## Current State Analysis
- 第一张截图：HUD 59 FPS，侧栏有基地模型，主 3D 区整片黑。原因是镜头先对准单位，随后 `force_opening_isometric()` 把视野夹到未开雾区。
- 第二张 `spawn_view.png`：镜头已对准基地，但地面是一张米色平涂，模型像蓝色蜡模，建筑脚下没有接触影。
- `showcase_world_scale = world_scale / 3.90625` 把 8m 高地当成 31m 台顶，镜头距离也被放大，近景直接走远景宏贴图。
- 大图为流畅删掉了 269 块水面网格，细致着色又只用岸带，湖心仍是沙色。
- 阵营 shader `team_mix=1` 把图集去饱和后乘纯色，嵌板/灯带全丢。
- `shadow_bias=0.3`、环境光 1.15、饱和度 0.75 把阴影和材质对比冲掉。

## Implementation Strategy
1. 开局：先定正交镜头，再对准本方单位；迷雾立刻刷一轮视野圈。
2. 大图锁只关体积雾 / SDFGI / SSR。阴影、MSAA、大气雾、Glow、SSAO 走画质档；环境光和阴影 bias 单独收紧。
3. 地形坐标按世界米；近景用有颗粒的沙地贴图；湖色画回高度场。
4. 阵营着色保留图集细节和高光。
5. 开一把带战争迷雾的对局截出生点，再关雾拉到湖心看分层。

## Implementation Steps
1. 本计划文档
2. 修 Match.gd 镜头顺序与光照
3. FogOfWar 开局立即同步视野圈
4. GeneratedTerrain 尺度 / 沙地 / 法线
5. showcase_land 把湖色画回地形
6. team_tint 不再整模纯色
7. 活局截图验收

## Timeline
改完立刻重开 G4 大湖截图。旧对局看不到热改。

## Risk Assessment
- 阴影 cascade 若再打穿帧率，只把 `directional_shadow_max_distance` 收到约 80m，不回到整屏黑或平涂。
- 战争迷雾语义不变：未探索仍是黑，己方视野内必须可见。关雾截图只用于验收湖面。

## Success Criteria
- 进局截图主画面能看见本方基地、工人、地面颗粒和接触影，不是整屏黑
- 关雾后能看见湖水/岸线/高差，不是整张米色卡纸
- 模型能看出图集嵌板，不是纯色蜡模
- 走动/采集后仍能保持可玩帧率（目标 ≥40）

## Progress Tracking
- ✅ 计划
- ✅ 镜头与迷雾
- ✅ 材质光照 / 湖色 / 阵营着色
- ✅ 地形/地图图集改 3D mipmap，地面按世界米双 UV 采样
- ✅ 活局截图：出生点、湖面、桥面

## Related Files
- `AI_RTS/source/match/Match.gd`
- `AI_RTS/source/match/FogOfWar.gd`
- `AI_RTS/source/PerformanceGovernor.gd`
- `AI_RTS/source/match/maps/generated/GeneratedTerrain.gd`
- `AI_RTS/source/match/maps/generated/showcase_land.gdshader`
- `AI_RTS/source/shaders/3d/team_tint.gdshader`
- `AI_RTS/source/net/DebugControlServer.gd`
