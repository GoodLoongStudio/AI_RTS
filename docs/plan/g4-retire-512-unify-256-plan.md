# G4 四人图淘汰 512、统一 256×256 Implementation Plan

## Overview
不再保留 512×512 评图。G4 四人图只认 **256×256**。删掉旧包和菜单/工具里的引用，避免再被选进局。

## Current State Analysis
- 菜单当前挂的是 `16-0-1ca6e21aa1`（256×256）。
- 旧包 `16-0-7d337ce8be` 仍在仓里，`size=[512,512]`。演示档案、冒烟、截图工具还写死它。
- 管线 `contract.py` 默认仍是 `W=H=512`，再跑 G4 会重新做出 512 图。
- `Match._is_oversized_generated_map` 是给 512 大湖的特例，图删了就没有存在必要。

## Implementation Strategy
1. 删除 `16-0-7d337ce8be` 目录和对应大厅预览 import。
2. 所有游戏/工具引用改到 `16-0-1ca6e21aa1`。
3. 发现生成图时：四人图不是 256×256 的直接跳过。
4. 管线默认画布改回 256。
5. 去掉 512 专用迷雾分支。

## Implementation Steps
1. 本计划
2. 删 512 包与预览
3. 改常量、档案、冒烟、工具路径
4. 改 contract 默认尺度
5. 无头冒烟对 256 图

## Timeline
本轮删干净即可。进自定义对局应只看到 256 大湖。

## Risk Assessment
- 历史文档里仍会提到 512，那是旧账，不当作现行评图。
- `16-0`、`16-0-794725b673` 也是 256，但不在菜单里；发现开关打开时仍可出现。
- 管线旧 512 跑次留在 `RTS_Map_Tool` 的 review 目录，不进游戏。

## Success Criteria
- 仓内没有可加载的 512 G4 四人图
- `MatchConstants.MAPS` 四人生成图只有 256×256
- 无头冒烟对 `16-0-1ca6e21aa1` 通过

## Progress Tracking
- ✅ 计划
- ✅ 删 512 包
- ✅ 改引用与管线默认
- ✅ 冒烟（256 图 PASS）

## Related Files
- `AI_RTS/source/match/maps/generated/16-0-7d337ce8be/`
- `AI_RTS/source/match/MatchConstants.gd`
- `AI_RTS/source/match/Match.gd`
- `AI_RTS/tools/verify_g4_large_lake_playable.gd`
- `RTS_Map_Tool/rtsmap/contract.py`
