# 科幻载具飞机换模 Implementation Plan

## Overview
用 4006 科幻世界（POLYGON Sci-Fi Worlds）替换对局里的载具和飞机外观。只换 Godot 场景网格和图集，不改 Core / 平衡表。

## Current State Analysis
坦克场景已指向悬停坦克，但 `assets/models/polygon-scifi` 里几乎只有 `.import`。直升机、无人机、工人仍是 Kenney Space Kit。科幻包没有传统直升机，用气垫艇/悬浮摩托作为空中单位外形。

## Implementation Strategy
- 只拷贝用到的 FBX + 共用图集，不把整包打进游戏资源。
- 白模用已有 `SyntyMaterialBinder` 绑 `PolygonScifiWorlds_Texture_01_A.png`。
- 单位逻辑、碰撞半径、移动域保持不变。
- 直升机去掉 Kenney 旋翼网格；脚本对 Rotor 做空判断。

## Implementation Steps
1. ✅ 从预览工程拷贝模型和图集
2. ✅ 坦克确认悬停坦克
3. ✅ 直升机改气垫艇，无人机改悬浮摩托，工人改科幻 buggy
4. ✅ 更新侧栏图标渲染棚

## Timeline
本轮只换外观。

## Risk Assessment
Synty FBX 轴向可能和 Kenney 不同，需要 180° 转向。模型尺度按现有占地缩放。素材来自已购/已入库的科幻世界包，不使用其他游戏模型。

## Success Criteria
对局里坦克、工人、直升机、无人机都是科幻世界外形，不再是 Kenney 小飞船/探测车。

## Progress Tracking
✅ 拷贝资源
✅ 换场景
✅ 图标棚
✓ 进局卡死：加载页预读 FBX、侧栏改为路径懒加载、图集缩小并共用材质
⏳ 用户再进自定义验收

## Related Files
- `assets/models/polygon-scifi/`
- `source/match/units/Tank.tscn`
- `source/match/units/Helicopter.tscn`
- `source/match/units/Drone.tscn`
- `source/match/units/Worker.tscn`
- `source/utils/IconRenderBooth.tscn`
