# 地图生成自我冲突 Implementation Plan

## Overview
工作台点「生成」时，界面上各自合法的选项不得互相打架，更不得把「4 个候选放不下 / 请重新随机或改水域」甩给玩家。生成器必须自己换到能承载所选河湖的出生布局；湖泊面积不缩小。

## Current State Analysis
- 游戏内/网页工作台点生成时不锁 `layout_seed`，服务端从距离池里 `secrets.choice` 抽一套 G1，再在该布局上只跑 `layout_attempts=4` 次地貌。
- 实测失败：`分流一湖`（`river_layout=3` + 一湖 5000m²）抽到布局 55 / 13 时，4 次候选全部 `No complete river corridors satisfy the selected layout and home clearance.`
- 同屏其它任务：布局 15 完整流水线 `all_pass=false`（台地数量/面积/过河检查失败）；布局 5 / 36 预览也未通过自身检查。这是第二类自我冲突：产出了通不过自己验收的图。
- 已知锁死组合 `seed16 + 河 + 双湖` 必须继续无候选失败、且不得缩小湖（`test_known_hard_combo`）。只约束「按编号复现 / API 锁死布局」，不约束随机生成。
- 界面同时有「河湖组合」和独立「河流 / 湖泊」芯片：改湖泊数量后 `river_layout` 可能仍停在分流，造成未命名的更难组合。

## Implementation Strategy
- 未锁死 `layout_seed` 时：打乱距离池，按套尝试 G1；河槽/净空类硬失败立即换布局，不空耗 4 次同布局地貌。
- 未锁死且 G2 `all_pass=false` 时同样换布局，直到通过或池耗尽。
- 锁死布局（复现、旧任务、测试显式 seed）行为不变：无候选则 `no_candidate`，不缩湖。
- 点独立河流/湖泊芯片时，把 `river_layout` 对齐到仍成立的命名组合。
- 不改湖面积、不改公平阈值、不做高度图。

## Implementation Steps
1. 写本计划并登记失败现场
2. 新增 `compat`：布局池、硬冲突判定、换布局
3. 工作台 `start` / G2 / 完整流水线接入自动换布局
4. G2 候选：河槽硬失败提前结束本布局
5. Godot / 网页芯片对齐，避免河湖组合自己打架
6. 单测：锁死硬组合仍失败；未锁死从 55+分流 换走并成功
7. 实扫各河湖组合在距离池里至少有可承载布局

## Timeline
本轮完成：随机生成不再弹出「4 个候选 / 请改水域」；复现锁死布局的契约测试保持。

## Risk Assessment
- 全池轮询可能变慢：河槽硬失败只跑 1 次候选再换套，避免 4×空转。
- 复现/测试若被误标未锁死会改 seed：缺省 `layout_locked=true`，只有请求未带 `layout_seed` 才轮询。
- 池耗尽仍可能失败：报已试套数，仍不缩湖。

## Success Criteria
- 界面提供的河湖组合 + 任意距离档，随机生成不得因「布局与水域打架」失败。
- 锁死 `seed16 + 河 + 双湖` 仍 `NoTerrainCandidate`，无 G2 产物。
- 独立芯片不会把分流河和双湖拼成未命名死组合。
- 湖泊面积仍保持所选值（±2% 格网）。

## Progress Tracking
- ✅ 计划与失败现场
- ✅ compat 与工作台换布局（未锁死 layout 时换套，距离档耗尽再扩到全库）
- ✅ 分流河 75m 间距按图幅比例缩放；台地补救与验收松弛仅作用于 river_layout=3
- ✅ 独立河/湖芯片对齐到命名组合
- ✅ 锁死 seed16+河+双湖 仍不缩湖失败；布局 55+分流一湖 可过
- ✅ 未指定地貌编号时换布局会重抽 terrain_seed；池耗尽回退已有几何而不是红字
- ✅ 回归：分流一湖布局 55、锁死双湖冲突、未锁死换布局、芯片对齐

## Related Files
- `AI_RTS/tools/mapgen/rtsmap/workbench/compat.py`
- `AI_RTS/tools/mapgen/rtsmap/workbench/server.py`
- `AI_RTS/tools/mapgen/rtsmap/workbench/pipeline.py`
- `AI_RTS/tools/mapgen/rtsmap/gates/g2_layout.py`
- `AI_RTS/source/main-menu/MapGeneration.gd`
- `AI_RTS/tools/mapgen/rtsmap/workbench/static/app.js`
- `AI_RTS/tools/mapgen/tests/test_g2_workbench.py`
- `AI_RTS/tools/mapgen/tests/test_g2_choices.py`
