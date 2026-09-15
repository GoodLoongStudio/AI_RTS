# 4 人 Seed 驱动科幻废土地图生成 · 总体方案与分闸门实施计划

> **当前 G2：v7.2（2026-09-06）**。已完成独立地貌Seed、12项调节参数、本地HTTP后端与43项回归；调参页面的app.js和浏览器联调待Terra完成，见 [G2-workbench-handoff.md](G2-workbench-handoff.md)。新默认候选在 `runs_v7_2` / `review_v7_2`。轮廓方向延续 [G2-v7.1-natural-landforms.md](G2-v7.1-natural-landforms.md)，保留3m高差；战略规则延续 [G2-v7-strategic-terrain.md](G2-v7-strategic-terrain.md)。下文旧版本记录仅作历史参考。

> 本文保留2026-09-03起的总体分闸门方案和历史记录；G2以顶部链接的v7.2交接、v7.1轮廓更新、v7战略规则及用户最新要求为准。
> 原始路线A（大平面+阻碍物）是历史起点；当前G2已将台地、坡道、完整河流纳入核心生成。素材范围仍为 `G:\AIRTS\AI_RTS\初选素材包` 中的 4006 科幻世界包。
> 旧的 P1–P4 / Image2 反推 / 2p 连续高度场文档（`设计契约-plan.md`、`P2反向求解规则.md`、`structured-mapgen-plan.md`、`.workbuddy/skills/rts-2p-ramp-debug`）已于同日删除，**不得恢复、不得作为依据**；`mapgen/`、`scripts/p2_*.py`、`output/p1_skeleton~p4_texture`、`tmp/` 只是待清理的历史遗留代码与产物。
> 实施分 **4 个闸门 G1→G4**，执行方 AI 每做完一个闸门必须停下等用户确认。可直接发送给执行方的指令见 `docs/plan/执行提示词.md`。
>
> 依据：2026-09-03 对 `G:\Command & Conquer Red Alert 2` 的实际解析（脚本与产物见 `docs/plan/ra2-reference/`）、对 `RTS_Map_Tool` 旧代码/产物的审读、对 `G:\AIRTS\AI_RTS` 消费端契约的调研。

---

## Overview

- 目标：为 `AI_RTS` 生成 **4 人、无水、科幻废土** 对战地图。出生点由 Seed 随机生成、经约束筛选；**主线为平面 + 阻碍物**（台地/坡道降为可选扩展，见策略 §0）；结构与表现（材质、物件、废墟）分离；成品直接使用 `G:\AIRTS\AI_RTS\初选素材包` 的 4006 科幻世界素材。
- 方法：**离散格网为唯一权威数据**，"参数 → 出生点 → 区域/通道 → 阻碍 → 资源 → 物件 → Godot 场景"逐层写入同一份格网；按 4 个闸门推进，**每个闸门出图 + JSON + 报告后暂停，等人工确认**才进入下一个。
- 第一个闸门只做最小实验：多 Seed 的 4 人出生点 + 边界 + 距离/角度/领地约束 + 通过/拒绝样本图集。

| 闸门 | 内容 | 用户看什么 |
|---|---|---|
| **G1** | 清理旧实现 + 出生点最小实验 | 出生点图、通过/拒绝拼图、接受率 |
| **G2** | 区域/通道骨架 + 阻碍布局 | 通道图、阻碍图、最短路图、咽喉宽度图 |
| **G3** | 资源与净空 + 素材实例化 | 资源归属图、物件图、公平表 |
| **G4** | Godot 场景导出 + AI_RTS 冒烟 | Godot 正交截图、与 Python 图的差分、5 分钟对局截图 |

---

## Current State Analysis

### 1. 旧方案（P1→P2→P3→P4，及其后继 `mapgen/`）为什么失败

> 下表"证据"列引用的旧文档已删除，结论保留作审计记录；引用的旧代码/产物仍在仓库中待清理（见 Related Files）。

| # | 失败根因 | 证据 |
|---|---|---|
| 1 | **图片是主产物，结构是副产物**。P1/P2/P3 以 `01_skeleton.png / 02_routes.png / 03_zones.png / 10~14` 等图片定义阶段，JSON 与 PNG 两套边界并存；数据通道 PNG 底部还烙进图例条带（`meta["legend_h"]` 需裁剪后再断言）。 | 旧契约 §一、附录文件清单 |
| 2 | **用 AI 图（Image2）反推结构**。`p2_from_p1_image2.py`、`tmp/image2_*` 共 15 版；"P2 反向求解规则"要求从 v15 图像"反推空间层级"。不可复现、不可证伪，导致契约 3 天内改到修订版 9。 | 旧 `P2反向求解规则.md`、`output/p4_texture/` 27 张 Image2、`tmp/` |
| 3 | **连续高度场 + 事后修补**。SDF+波形+倒角+"打口袋"+末尾镜像循环，坡道是在连续场上"刻"出来再抽样验 30°。A6/A10 类失败反复出现，甚至专门写了一份排障 skill。结构靠事后断言兜底，而不是构造上保证。 | 旧 `rts-2p-ramp-debug/SKILL.md`、`mapgen/height.py` 三次 `_carve_ramps` + `enforce_rot180` |
| 4 | **"生成器"实为写死模板**。`mapgen/layout.py` 中出生点 `18.2 + jx*0.8`（Seed 只抖动 ±0.4 m），台地/坡道/资源坐标全部硬编码；`validation.json` 永远 `passed: true`，是自证。 | `layout.py` L46–160、`output/maps/seed_42/validation.json` |
| 5 | **范围与目标不符**。2 人、96×48、180° 点对称烙进每一层（`rot180_xz`、`enforce_rot180`、`players == 2` 断言）。4 人非对称从现有代码不可达。 | `constants.py PLAYER_COUNT = 2`、`validate.py` L49 |
| 6 | **投影与画布不统一**。3D 预览是透视相机（`Preview3D.gd` `camera.fov = 38`），P1/P2 画布 1920×966，栅格分别 0.2 / 0.05 / 0.25 m，多套坐标约定。 | `output/maps/seed_42/preview_3d.png`、`Preview3D.gd` L46–47 |
| 7 | **没有消费端契约**。`AI_RTS` 中不存在任何读取 `map.json / height.f32 / MapSpec` 的代码；地图工具的产物从未被真正消费，只在工具内部自检。 | AI_RTS 调研（见 §消费端事实） |
| 8 | **流程上没有人工闸门**。AI 一次生成整图 → 跑断言 → 失败就加断言/打补丁，用户看到的是最终图，无法在中途纠偏。 | 旧契约 §七"断言体系"22+17 条 |

结论：**不能在 P1/P2/P3/P4 上打补丁**。问题不在参数，而在"图片为权威、连续场、写死模板、无闸门"四个结构性错误。

### 2. 从红警 2 本地文件确认的事实（✅ 已解析验证）

本机安装是**不完整安装**：缺 `RA2.MIX` / `LANGUAGE.MIX`（GAME.EXE 中引用 `RA2.MIX`、`LOCAL.MIX`、`CACHE.MIX` 但目录内不存在），`THEME.MIX`/`Movies01.mix` 为 5 字节占位。可解析的有 `GAME.EXE`、`MULTI.MIX`、`Maps01/02.MIX`、`WDT.MIX`、`RMCACHE\`。

**A. GAME.EXE 中的随机地图生成器（RMG）证据**（`ra2-reference/game_exe_rmg_strings.txt`）

- 源文件路径字符串 `C:\RA2\MapGen.cpp`；RTTI 类名 `MapSeedClass`、`MapRegionClass`、`VectorClass<MapRegionClass*>`、`VectorClass<PassabilityType>`、`SubzoneConnectionStruct`。
- 13 条进度字符串：`RMG: Init random map / Seeding water / Init regions / Making regions / Recalculating cell attributes / Creating starting points / Adding tech buildings / Creating tiberium / Creating hills / Creating LATs, rocks etc / Cleanup / Compute Radar Image / Done`。
- 种子文件（`.sed`，`lastmap.sed`、`RandMap.Sed`）`[Random Map]` 节键名：`Seed, NumPlayers, Width, MapType, RegionSize, Ruggedness, Accessibility, WaterAmount, TiberiumLayout, Vegetation, UrbanPresence, Resources`；输出 `RandMap.Map`、`RandMap.img`；日志 `Saving random map: %s` / `Loading random map: %s`；随机地图文件模式 `*.MPR`。
- UI 枚举：MapType {Archipelago, Continent, Team Continents, Inland, Mountainous}；Resources {Low, Moderate, High, Extreme}；MapSize {Small, Medium, Large, Very Large}；Theater {Temperate, Snow}；Time {Morning, Afternoon, Dusk, Night}。
- `RMG.INI` 文件名及键：`RMGMinimumTiberium / RMGMaximumTiberium / RMGLevelLightSettings / RMGVegetationMinimums / RMGVegetationMaximums / MaxTrees / TemperateOrePatchLamps / SnowOrePatchLamps / *AmbientLight / *AmbientRed|Green|Blue`。
- 剧场 INI 键（引擎读取 tileset 语义）：`TileSet%04d, TilesInSet, RequiredForRMG, AllowTiberium, AllowToPlace, Morphable, HeightBase, RampBase, RampSmooth, MMRampBase, CliffSet, CliffRamps, SlopeSetPieces, WaterSet, ShorePieces, ClearTile, RoughTile, SandTile, GreenTile, PaveTile, ClearTo*Lat, Rocks, DirtRoad*, PavedRoad*, DestroyableCliffs, WaterCliffs, Bridge*, Tunnels ...`。
- RNG：`Seed is %08x` / `Init random number`。
- 目录扫描：`rmcache\*.mmp`，与 `RandomMap`、`RandMap.*` 字符串相邻。

**B. MIX / 地图格式**（`ra2-reference/tools/mixprobe.py`、`mapparse.py`）

- MIX 头以 Westwood RSA 公钥 + Blowfish 加密（flags `0x0002`），已解密：`MULTI.MIX` 97 个条目全部是多人地图 INI；`Maps01/02.MIX` 各 17 张战役地图 + 1 个文本；文件名按 `mpNNtP.map` 规则命中 18 个（其余为同图变体，见推论）。
- 地图 INI 节顺序：`SpecialFlags, Ranking, Basic, Lighting, Preview, PreviewPack, Map, Waypoints, IsoMapPack5, Terrain, Structures, (Units), OverlayPack, OverlayDataPack, ..., Digest`。
- `[Map]`：`Size=0,0,W,H`、`LocalSize`、`Theater=TEMPERATE|SNOW|URBAN`。
- `IsoMapPack5`：Base64 → 分块（u16 压缩长 + u16 原长）→ **LZO1X** → 每格 11 字节：X u16、Y u16、TileIndex i32、SubTile u8、**Level u8**、1 字节标志。
- `OverlayPack / OverlayDataPack`：同样分块，**LCW(Format80)** 压缩，512×512 字节，每格 1 字节覆盖物索引（0xFF 空）。
- `PreviewPack`：分块 **LZO**（用 LCW 解码会越界失败），24 bit/像素，尺寸取自 `[Preview] Size=0,0,W,H`（97 张图 40 种尺寸，例 208×95、166×91）。
- `[Waypoints]`：`索引=Y*1000+X`；多人图以 0..N-1 号路点为出生点（数据，而非烙进地形）。
- **高度**：Level 取值 0..12（观测最大 12，理论 0..14）。相邻格 |ΔLevel| 分布：0 → 93.8%，**1 → 5.0%（坡）**，**4 → 1.17%（崖）**，3 → 0.03%，2 → 0。即崖=一次跳 4 级，坡=每格 1 级。
- Level 占比（59 张标准多人图）：L4 31.6%、L2 18.5%、L8 15.6%、L0 6.2%，奇数级合计约 20%（坡与"丘"）。
- **97 张多人图统计**（`ra2_ref_stats.png`、`ra2_ref_summary.json`）：4 人图 39 张标准样本，Size W 79–150、H 60–150；**出生点最小两两距离 43.8–88.4 格，归一化 minPair/√(W·H) = 0.48–1.01，中位 0.73**；2 人图 0.59–1.47；6 人图 0.33–0.44。每个出生点到最近矿格：p10 = 7.1、**中位 12.1**、p90 = 51.8 格。
- `RMCACHE\`：90 个 `.MMP`，只有 4 种尺寸（146×81 ×39、152×85 ×35、158×87 ×10、166×91 ×6），文件头 `0A 05 01 08` + (w-1,h-1,w,h)；与多人图 40 种预览尺寸**不匹配**。
- 目录中**没有** `.mpr` 随机地图文件、`RMG.INI`、`TEMPERAT.INI`；本机全盘也没有 `MapGen.cpp` 源码。

**C. 消费端（AI_RTS）事实**

- 主工程是 `G:\AIRTS\AI_RTS`（不是 `godot-open-rts`）。地图 = 继承 `source/match/Map.tscn` 的 `.tscn`，`Map.gd` `size: Vector2`（**米**），现有 `PlainAndSimple` 4 人 50×50、`BigArena` 8 人 100×100。
- 地形 = 单张 Y=0 `PlaneMesh`；无高度图/GridMap。`Constants.Match.Terrain.PLANE = Plane(UP,0)` 被点击射线、蓝图放置、小地图、框选引用；空域 `Air.Y = 1.5` 写死。
- 导航：地面 cell 0.3、agent_radius 0.9、agent_max_climb 0、烘焙 AABB 高 5；`agent_max_slope` 未设（Godot 默认 45°）。单位只有 GROUND / AIR 两个域，无两栖。
- 出生：`SpawnPoints/Marker3D`；开局 1 CommandCenter（footprint 半径 2.0 m）+ 1 Drone + 2 Worker（偏移 ±3 m）。资源 `ResourceA/B` Area3D 手摆，贴靠中心距 ≈1.7 m，自动搜矿半径 30 m。
- AI_RTS 内**没有**任何导入 `map.json / height.f32 / MapSpec` 的代码。

### 3. 根据事实得出的推论（🔶 推论）

- RMG 的**执行顺序**就是上面 13 条的列出顺序：MSVC 6 把同一编译单元的字符串倒序排布，同区段的 `TXT_MAPSIZE_VERY_LARGE→SMALL`、`TXT_RESOURCE_EXTREME→LOW` 等枚举同样倒序，可作交叉验证。因此红警 2 是 **"参数 → 水 → 区域 → 格属性 → 出生点 → 科技建筑 → 矿 → 丘/高度 → 贴图/岩石 → 清理 → 雷达图"**，高度在出生点和资源之后。
- `MapRegionClass` + `.sed` 的 `RegionSize` 说明 RMG 以"区域"为基本单元做地貌决策，之后才逐格重算属性（`PassabilityType`），与 `SubzoneConnectionStruct` 一起构成寻路连通判断。
- `RMCACHE\*.MMP` 是**随机地图预览缓存**：4 种尺寸恰对应 4 档地图大小，且与官方图预览尺寸不匹配；`.sed` 只存参数，靠 Seed 重生成，图像另存缓存——这是红警 2 的 Seed 复现机制。
- 97 张多人图中大量"同尺寸同出生点"的多文件（如 84×92 有 ~25 张、矿量为 0 但中立建筑更多的变体）是**同一张图的不同游戏模式变体**（无矿+多油井 = Megawealth 类），说明红警 2 把"结构层"（格/高度/出生点）和"经济/物件层"分文件复用。
- 崖高 4 级、坡每格 1 级 → 一条完整坡道长 4 格；这是"离散层 + 固定坡长"的模块化地形，而不是连续高度图。

### 4. 尚未确认的内容（❔）

- `RMG.INI`、`TEMPERAT.INI / SNOW.INI` 的实际内容（文件不在本机）。
- RMG 如何选出生点、是否有对称/公平约束、`Accessibility / Ruggedness` 的具体算法语义。
- `.MMP` 像素编码（数据区非 LCW/LZO 直解）。
- 矿覆盖物索引 102–121 / 宝石 27–38 是凭记忆设定的（矿簇位置合理，但未用本机 `rules.ini` 核对；`mp01t4` 中"宝石"沿海岸线分布，存疑）。
- 参考图集中**水面未区分**：格的地类来自 tileset（剧场 INI 不在本机），重绘图只按 Level 着色，岛图（如 `mp01t4`）周围的 L0 大片即为水。
- `PreviewPack` 像素字节序：目视 R,G,B 顺序渲染出正常的绿色温带地貌（`ra2_ref_preview_channels.png`），未与引擎代码核对。

---

## Implementation Strategy

### 0. 路线选择（2026-09-03 用户拍板：**路线 A**）

| | 路线 A：**大平面 + 阻碍物**（主线） | 路线 B：台地 + 坡道（可选扩展，A 跑通后再评估） |
|---|---|---|
| AI_RTS 是否要改 | **不用改**。`PlainAndSimple.tscn` 就是"Y=0 平面 + SpawnPoints + Resources + 装饰 StaticBody3D 进 `terrain_navigation_input`"，导出同构场景即可加载 | 必须改主工程：点击射线/蓝图/小地图从 `Plane(UP,0)` 改打地面碰撞、空域 `Air.Y=1.5` 改相对地面、烘焙 AABB；跨仓库、跨团队 |
| 玩法结构靠什么 | 不可通行的岩群/废墟/残骸/围墙簇 + 它们围出的通道与咽喉；开阔区 = 战场 | 层差 + 崖 + 坡道 |
| 生成难度 | 低：格网上标 `blocking`，通行 = 非遮挡格腐蚀 0.9 m 后 BFS | 中高：坡道构造、崖生成、3D 阶梯网格、navmesh 坡度 |
| 直接可玩概率（估） | **约 85–90%**（见 §风险） | 约 30–50%，且卡点在 AI_RTS 而非本工具 |
| 素材 | 4006 科幻世界包现成：`SM_Env_Rock/Rock_Large/Rock_Spike/Cliff_*/Crater_Edge/Artifact_AlienRuin`、`SM_Bld_Scav_Wreckage/Scav_Refinery_*/Corp_Wall*/Platform_*`、`SM_Prop_Scav_Scrap/Crate/Turret_Large/SolarPanel/Antenna` | 需自建崖壁/坡道模块或改造 `Cliff_*`、`Ground_Slope`、`Pod_Ramp` |

决定：G2 的阻碍布局取代任何高度结构；G4 不构建高度网格，只做平面 + 实例化物件 + navmesh 烘焙。

**可选扩展（尚未决定，不进入 G1–G4 范围）**
- 台地 + 坡道（路线 B）。
- **水面作为"地面不可走、两栖可走"的特殊阻碍**（用户 2026-09-03 提问）：生成侧只是多一种 `terrain=water` 与按单位域分开的 `passable_ground / passable_amphib` 两个通道，难度低；表现侧水面与地面同在 Y=0（只换材质 + `SM_Env_LakeEdge_*` 岸边件），不引入高度；难点在 AI_RTS 需新增两栖域（第二块 navmesh 区域 + `navigation_layers`、单位 `domain=AMPHIBIOUS`、AI 寻路），属跨仓库改动。若采纳，放在 G2 加 `--water` 开关（默认关，水占比 ≤ 15%，任何通道不得被水完全切断），AI_RTS 侧另立计划。

素材事实（已核对，2026-09-03）：素材根目录为 **`G:\AIRTS\AI_RTS\初选素材包`**（`_筛选解包` 的同结构副本）。其中 `目录.md` 描述的 `素材包\` 子目录**不存在**，FBX 实际位于 `初选素材包\工程\预览渲染工程\assets\4006_科幻世界\PolygonSciFiWorlds\Models\`（1228 个非碰撞 FBX：Prop 443 / Bld 310 / Env 224 / Chr 79 / Wep 73 / Veh 44；`Collision\` 子目录下的 `*_Collision.fbx` 不用于渲染），已被 Godot 4.7.1 导入；`初选素材包\工程\预览渲染工程\texture_map.json` 已给出 3464 条 fbx→图集映射，材质问题已有现成解法。G3 的 `assets_catalog.json` 以该路径为准。

### 1. 红警 2 中值得迁移 / 不应照搬

| 迁移 | 不照搬 |
|---|---|
| 阶段顺序：参数 → 区域 → 出生点 → 资源 → 地貌 → 表现 → 预览 → 存档 | 等距 2:1 投影及其预览（我们要垂直正交俯视） |
| **离散格网**，通行由构造规则保证，不是连续场 | 0..14 级高度、崖 4 级（路线 A 不做高度） |
| 结构层（格/出生点）与覆盖物层、物件层、预览层**分文件/分数据**，同结构可换经济与表现 | 水域、群岛/大陆等 MapType、矿蔓延 |
| Seed + 参数文件复现，预览单独缓存 | INI + Base64 + LZO/LCW 的文本容器 |
| tileset 标志（`RequiredForRMG / AllowToPlace / Morphable`）→ 资产目录标志 | 红警 2 常见的四角固定出生 |
| 出生点作为路点数据，不烙进地形 | 用 `.mpr` 完整图作为唯一产物（我们要保留每个闸门的中间态） |

### 2. 新管线是否还需要 P1/P2/P3/P4

不需要这套命名和分工。P1–P4 绑定的是"某张 PNG"与 Image2 反推；新管线按**数据层**分 4 个闸门，每层写回同一份格网，图片只是派生视图。旧目录 `output/p1_skeleton ~ p4_texture` 归档，不再写入。

### 3. 唯一权威来源

`MapGrid`（单文件、版本化、可哈希）：

```
runs/<seed>/<gate>/mapgrid.npz      # 全部格网通道（唯一权威，二进制）；<gate> ∈ G1..G4
runs/<seed>/<gate>/mapspec.json     # 头信息 + 非格网对象（出生点、通道、阻碍簇、资源点、物件、参数、版本、输入哈希）
runs/<seed>/<gate>/*.png            # 派生诊断图（可随时重画，不回读）
runs/<seed>/<gate>/manifest.json    # seed / gate_seed / algo_version / params / input_hash / output_hash / approved
```

格网通道（cell = 1 m，默认 96×96，可参数化）：G1 写 `territory:u16`（Voronoi 领地）；G2 写 `role:u8`（home / center / flank / expansion / hinterland）、`region:u16`（编号）、`lane_core:u8`（通道核心带位标）、`terrain:u8`（clear / rock / ruin / wall / debris / crater）、`blocking:u8`（遮挡）、`passable:u8`（派生：blocking 8 邻域膨胀 1 格后取反）；G3 写 `overlay:u8`（资源 A/B），并用实例真实包围盒**重算** `blocking / passable`（G2 原值另存 `blocking_g2`）；G4 不新增通道。

世界坐标：X∈[0,W]、Z∈[0,H]，原点在西北角，中心 (W/2,H/2)；格 (i,j) 覆盖 X∈[i,i+1)、Z∈[j,j+1)。出生点、资源点、折线用连续米坐标。

约定："**图片不回读**"、"**下游 npz = 上游全部通道原样复制 + 本闸门新增通道**（G3 重算 blocking 是唯一例外）"、"**上游未 approved，下游拒绝运行**"。

### 4. 受约束的 4 人随机出生点

采样：Seed → 闸门子 Seed（`sha256(master_seed, "G1", algo_version)`）→ `numpy PCG64`。
生成 P0 在允许环带内均匀取；P1..P3 用"最佳候选"法：每次抽 k=32 候选，取对现有点最小距离**最大的前 30%**中随机一个（避免退化到四角）。
硬约束（默认值来自红警 2 统计与 AI_RTS 尺度，G1 可调）：

| 约束 | 默认 | 依据 |
|---|---|---|
| 边界留白 | ≥ 12 m（基地盘 10 m + 2） | HQ 半径 2 m，开局单位偏移 3 m，需建造展开 |
| 两两最小距离 | ≥ 0.50·√(W·H)（96×96 → 48 m），系数可调 | 红警 2 4 人图归一化 0.48–1.01，中位 0.73。2026-09-03 用同一采样器做 64 Seed 模拟：0.50 → 接受率 ~75%、四角退化 ~11%；0.55 → 接受率 ~28%、四角退化 ~24%（更紧的距离会把点挤向四角，与"不固定四角"冲突），故默认取 0.50 |
| 到中心距离 | ≥ 0.25·min(W,H)（24 m） | 中央必须是争夺区，不能被某家"住进去" |
| 角度分布 | 绕中心排序后相邻夹角 45°–150° | 防止三家挤一侧 |
| 公平 | 到中心距离 max/min ≤ 1.35；Voronoi 领地面积 max/min ≤ 1.3；各家"最近邻距离" max/min ≤ 1.3 | 无对称时的公平代理 |

失败即拒绝并记录原因；报告接受率。接受率 < 5% 视为约束过紧，回到参数而不是改采样器。可选对照采样器 B（旋转模板 + ±15% 抖动）只用于让你对比风格，不默认。

### 5. 避免过近 / 失衡 / 堵塞 / 封锁

- 过近：G1 硬约束 + 图上画最小距离线段与距离矩阵。
- 资源失衡：G3 按"每家 2 近矿 + 扩张矿 + 共享侧翼矿 + 中央矿"配额；用 G2 通行格网上的**路径距离**（不是直线）计算每家到各类资源的距离并做 max/min 带宽检查。
- 通道堵塞：G2 先定义通道图（每家 → 中央、每家 → 两邻家侧翼）并标出通道核心带，阻碍**由构造保证**不进核心带；每放一簇就重跑连通检查，不通则撤销；G3 用实例真实包围盒重算后再复检。
- 封锁：可走区连通分量只允许 1 个；通道最窄处 ≥ 6 m；侧翼通道用"咽喉整形"收到 8–12 m 而不是碰运气；用 `agent_radius 0.9` 做形态学膨胀后再测连通。

### 6. 每一步可人工校验

统一画布：**2048×2048**，地图区 1920×1920（20 px/m），四周 64 px 放坐标刻度与图例（图例永不进入数据区）。方向：**垂直向下正交投影**——Godot 中相机沿 −Y 看（若按 Z 向上的 CAD 惯例即 −Z），图像 x = 世界 +X（东），图像 y = 世界 +Z（南），图像上方 = −Z（北）。Python 诊断图与 Godot `PROJECTION_ORTHOGONAL` 顶视截图**逐像素对齐**，可直接做差分图。每个闸门固定输出：单 Seed 大图、多 Seed 拼图（contact sheet）、拒绝样本拼图（带原因）、`report.json`、`summary.csv`；G4 附 Godot 正交俯视截图与 45° 斜视参考图（后者仅供观感，不作验收）。

### 7. Seed / 参数 / 版本 / 中间结果保存

`manifest.json` 记录：master seed、闸门子 seed、`algo_version`（每个闸门独立语义化版本）、参数快照、上游 `mapgrid.npz` 哈希、本闸门输出哈希、生成时间、git commit、`approved: true/false + 备注`。同 Seed 同版本重跑必须字节级一致（用哈希做回归）。运行目录按 Seed 归档，不覆盖；`runs/index.json` 汇总所有 Seed 的闸门状态。用户通过 `python run.py --approve G1 --seeds ...` 放行，后续闸门只跑被放行的 Seed。

### 8. 第一张可验证的实验地图

G1 只做"边界 + 4 出生点 + 距离/角度/领地约束"（空格网连通性平凡，但要输出 Voronoi 领地与"争夺带"热图，为 G2 提供直观预期）。不生成任何阻碍或地形。

---

## Implementation Steps（4 个闸门，每个闸门结束暂停等确认）

### G1 清理 + 出生点最小实验 — ⏳（可开始）
- 目标：清掉旧实现；验证"Seed 驱动 + 约束筛选"的 4 人出生位置是否符合预期。
- 输入：契约参数（W,H,N=4,约束表）、Seed 列表（默认 1–64）。
- 步骤：① 旧 `mapgen/ scripts/ preview/ tests/ output/ tmp/ *.log` 移入 `_legacy/`；② 建 `rtsmap/` 包骨架；③ 出生点采样 + 约束筛选 + Voronoi 领地。
- 输出：`runs/<seed>/G1/mapspec.json`（starts、距离矩阵、角度、Voronoi 面积、通过/拒绝原因）、`mapgrid.npz`（`territory`=Voronoi 领地）、`starts.png`、`starts_table.png`、`territory.png`（领地 + 争夺带热图）；汇总 `runs/G1_summary/`：`contact_accepted.png`、`contact_rejected.png`（每格标拒绝原因）、`hist.png`、`summary.json/csv`、`README.md`。
- 验收：系数 0.50 下接受率 30%–95%（与预校准同量级）；四角退化率（出生点到最近地图角 < 24 m 的比例；留白 12 m 时角点最近 17 m，故阈值不能取 15）< 15%；用户目视 ≥16 张通过样本认可布局风格；另附系数 0.55 的对照汇总。
- 校验：脚本断言全部硬约束 + 同 Seed 重跑哈希一致 + 单元测试（必拒绝样本、画布往返精度）。
- 返工：只改约束表/采样器参数 → 重跑；不进入 G2。
- 放行：用户 approve 3–6 个 Seed 进入 G2。

### G2 区域/通道骨架 + 雕刻式布局 — ✅ 雕刻式 v2 待确认（2026-09-04）

> **偏差记录（2026-09-03 晚）**：G2 第一版按"区域圆 + 撒阻碍簇 + 密度 + 连通过滤"实现，12 个 Seed 全部通过断言，但图面是均匀碎块噪声，没有咽喉和有分量的墙体——这是方案设计错误（撒 + 过滤 = 噪声，与旧方案"连续场 + 断言"同类），不是执行错误。改为**雕刻式**：全图先为实体，挖出基地 / 中央战场 / 侧翼会战场 / 扩张口袋 / 变宽度通道 / 侧口袋，剩余实体即墙体；实体占比目标 25–40%，实体块 8–25 个；侧翼通道带显式咽喉 6–8 m。同时把产物精简为 `review/<gate>/`（contact + summary.md + 每 Seed 一张 overview），分项 PNG 仅 `--detail`。详细规格见 `docs/plan/执行提示词-修订1.md`。另外 G1 撤销"四角退化率"验收线：4 人 + 0.5·√(W·H) 间距在几何上必然落在四个象限外侧（红警 2 官方图亦如此），地图变化靠雕刻出，不靠出生点乱跑。

- 目标：在通过的出生点上划分 home / expansion / center / flank 挖开区，建立变宽度通道，从整块实体中雕刻出开放空间；通行与咽喉由构造保证。
- 输入：G1 approved 的 `mapgrid.npz`；阻碍簇模板库（岩群、废墟块、管线墙、残骸、弹坑环、废料堆）。
- 区域默认（优先级 home > center > flank > expansion > hinterland）：home 半径 14 m；center 半径 0.2·min(W,H)=19 m；flank 以相邻两家出生点中点为锚（到中心不足 33 m 则外推到 33 m）、半径 14 m；expansion 锚点 = 出生点朝中心偏转 ±35° 前进 20 m（到中心 < 27 m 或到边 < 10 m 时改 ±60°，再不行朝最近 flank 锚点方向）、半径 8 m。
- 通道默认：主攻 出生点→中心 宽 10 m；侧翼 出生点→flank 锚→邻家 宽 8 m；每段 1 个 Seed 驱动的偏移路点（不许直线）。核心带写入 `lane_core`。
- 阻碍默认：可放置区 = `lane_core==0` 且到任一出生点 ≥ 12 m；密度 flank 25–40%、hinterland 15–25%、center 5–10%（只放掩体）、expansion ≤5%、home 0%（装饰留给 G3）；全图 8–20%。逐簇放置，重算 `passable`（8 邻域膨胀 1 格取反）后 BFS（8 邻域禁穿角）检查关键点集（4 出生点 + 中心 + 4 侧翼锚点）连通，不通即撤销；结束后填口袋、咽喉整形（侧翼最窄 8–12 m，主攻最窄 ≥ 8 m，任何通道 ≥ 6 m；宽度沿折线每 2 m 采样、法向两侧到第一个 blocking 格）。
- 输出：`regions.png`、`lanes.png`、`lanes.json`、`obstacles.png`、`passability.png`、`paths.png`（每家→中心/两邻家最短路 + 长度）、`chokes.png`、`obstacles.json`、`report.json`；汇总 `runs/G2_summary/contact.png`。
- 验收：各家主攻通道长度 max/min ≤ 1.3；各家两条侧翼长度和 max/min ≤ 1.3；中心区面积 10%–20%；可走区连通分量 = 1；通道最窄处满足上述宽度；阻碍占比 8%–20%；路径长度比 ≤ 1.3；基地盘 10 m 内无阻碍。
- 返工：调区域半径/通道宽/模板/密度 → 重跑 G2；不改 G1。出生点本身不可救的 Seed 记为 G1 拒绝原因"不可分区"。

### G3 资源与净空 + 素材实例化 — ⏳
- 目标：按配额放资源并保证净空与公平；再把阻碍簇（结构）落成具体 FBX 实例（表现），铺不遮挡的装饰。
- 输入：G2 approved；`assets_catalog.json`（来自 4006 包：FBX 名、包围盒、图集、类别、是否遮挡、允许的 terrain 类）；`PlainAndSimple.tscn` 的资源密度作基线。
- 资源默认：每家 2×A（路径距离 8–13 m，home 内）+ 扩张 1×A+1×B（18–28 m）；每条侧翼 1×A（到两邻家路径距离差 ≤ 20%）；中心 2×B+1×A。净空：非 blocking、距 blocking ≥ 2 m、资源间 ≥ 3 m、不在核心带、不在基地盘 6 m 内。
- 实例化默认：结构类 → FBX 候选映射（rock/ruin/wall/debris/crater 各一组）；位置吸附格中心，朝向 90° 步进（岩石可随机 + 0.9–1.2 缩放）；用实例真实 AABB 膨胀 0.9 m 重算 `blocking` 并复跑 G2 全部检查，失败换小件或删；装饰不进基地盘 10 m、不压资源 2 m、不进核心带；实例预算 ≤ 1500。
- 输出：`resources.png`、`resources.json`、`resources_table.png`、`objects.json`、`objects.png`（遮挡红、装饰灰）、`recheck_report.json`、`assets_used.json`。
- 验收：配额保证每家归属数量相等；三项路径距离比各 ≤ 1.3（到 2 个近矿之和、到扩张 A、到左右共享矿之和）；复检全过；实例数 ≤ 预算；实例包围盒覆盖原簇格 ≥ 90%。
- 返工：调配额/距离带/映射/密度 → 重跑 G3；不改 G1/G2。

### G4 Godot 场景导出 + AI_RTS 冒烟 — ⏳
- 目标：导出继承 `AI_RTS/source/match/Map.tscn` 的地图场景并在 AI_RTS 中打一局。
- 输入：G3 approved；`assets_used.json`。
- 导出：`AI_RTS/source/match/maps/generated/seed_<N>.tscn`（文本生成）：`size=Vector2(96,96)`、Y=0 平面不动、`SpawnPoints/Marker3D×4`、`Resources` 实例、`Decorations` 下 FBX 实例 + `material_override`（图集来自 `texture_map.json`），遮挡物挂 `StaticBody3D + BoxShape3D`（实例 AABB 的 XZ × 高 2 m）并进 `terrain_navigation_input`，装饰物不挂；只复制 `assets_used.json` 中的 FBX 与图集到 `AI_RTS/assets/models/scifi-worlds/`。
- 校验：`tools/godot/ortho_capture.gd` 正交顶视截图（`size=96`，位置 (48,50,48)，旋转 (−90,0,0)，视口 1920² 抓帧后由 Python 贴入 2048 画布 (64,64) 处并加边框；另出一张遮挡红/装饰灰/地面白的平涂图供差分）→ `diff.png`；材质用 `Decorations` 节点上的 `ApplyAtlas.gd` 在 `_ready()` 统一挂图集，不在 .tscn 里覆写实例内部子节点；`tools/godot/bake_probe.gd` 用 AI_RTS 同参数烘焙 navmesh 并用 `map_get_path` 测 4 出生点两两及到中心连通 → `navmesh_report.json`。
- 冒烟：`MatchConstants.gd MAPS` 加一条登记；优先用 `AI_RTS/tests/`、`AI_RTS_verify` 已有脚本，否则给用户手动开局步骤；4 名 AI 对战 5 分钟，30 s / 5 min 各截一张，收集日志 ERROR/WARNING。
- 输出：`ortho_godot.png`、`diff.png`、`oblique.png`、`navmesh_report.json`、`smoke_log.txt`、`smoke_30s.png`、`smoke_5min.png`、`smoke_report.json`。
- 验收：差分不一致率 < 2%；navmesh 烘焙 < 10 s、4 出生点两两连通；无白模；无脚本报错；4 家均有 Worker 采矿；无单位卡死。
- 返工：只改导出器/资产映射/碰撞盒，不改格网。
- 允许改动 AI_RTS 的范围：仅新增 `maps/generated/`、新增 `assets/models/scifi-worlds/`、`MatchConstants.gd MAPS` 加一行。

---

## Timeline

| 闸门 | 预计工作量 | 用户看什么 |
|---|---|---|
| G1 | 1 个工作日 | 64 Seed 出生点图集、接受率 |
| G2 | 2–3 天 | 通道/阻碍/路径/咽喉图 |
| G3 | 2–3 天（含 4006 资产目录整理） | 资源图、物件图、公平表、复检 |
| G4 | 1.5–2 天 | Godot 正交截图差分、navmesh 报告、4 人 AI 冒烟截图 |
| 可选扩展（台地 / 水面两栖） | 另立计划（含 AI_RTS 改动） | — |

---

## Risk Assessment

### "直接能玩"的概率估计（路线 A）

"能玩"定义：`.tscn` 能被 AI_RTS 加载、navmesh 烘焙成功、4 家 AI 开局采矿并能互相到达、无脚本报错。综合估计 **85–90%**；剩余风险及其权重：

| 风险 | 概率 | 后果 | 缓解 |
|---|---|---|---|
| 材质：FBX 进 Godot 是白模，需运行时挂图集 | 中（~15%） | 能玩但难看 | `texture_map.json` 已有 3464 条映射；G4 验收含"无白模" |
| navmesh：上千个 StaticBody 烘焙慢或留 <0.9 m 缝 | 低–中（~10%） | 卡单位、烘焙超时 | 遮挡物用**格网 footprint 的简化盒**做碰撞而不是 FBX 三角网；导出前 0.9 m 膨胀检查；只有遮挡物进 `terrain_navigation_input` |
| 经济：资源数量/距离与 AI_RTS 内建 AI 的采集逻辑不匹配 | 中（~15%） | AI 不出兵、经济停滞 | 先用 `PlainAndSimple` 的资源密度做基线；G3 验收加"每家 30 m 搜矿半径内 ≥ 2 个资源" |
| Godot .NET 导入 FBX 到 AI_RTS 仓库体积/时间 | 低 | 首次导入慢 | 只复制 G3 实际用到的 FBX（预计 < 60 个） |
| "公平"≠"好玩" | 必然 | 需人工迭代 | 这就是分闸门的意义 |

路线 B（台地）"直接能玩"概率约 30–50%：不确定性不在生成器，而在 AI_RTS 大量逻辑钉在 `Plane(UP,0)` 与 `Air.Y=1.5`，需要跨仓库改动与团队协调。水面两栖扩展同理：生成侧容易，AI_RTS 侧需新增两栖导航域。

### 其它风险

- **约束过紧导致接受率过低 / 过松导致布局无趣**：G1 用接受率与分布直方图量化，先观测再收紧。
- **无对称下的公平只是代理指标**：G2/G3 用路径距离而不是直线；保留"对照采样器 B"供对比；必要时引入"局部镜像"作为可选参数而非默认。
- **本机 Python 环境**：matplotlib 与 numpy 2.5 不兼容 → 诊断图全部用 Pillow 自绘；依赖清单锁定 numpy + Pillow（+ scipy 可选）。
- **素材目录与文档不一致**：`目录.md` 所述 `素材包\` 不存在，FBX 只在 `工程\预览渲染工程\assets\` 内；G3 资产目录以该路径为准。

---

## Success Criteria

- 任一闸门的产物可由 `seed + manifest` 字节级复现。
- 每个闸门有且只有一份权威 `mapgrid.npz`，图片可全部删除后重画且不变。
- G1：≥16 张通过样本获用户认可；四角退化率 < 15%；接受率 30%–95%（系数 0.50）。
- G2：全部放行 Seed 的连通/路径比/咽喉宽度断言通过，且无任何"事后修补"步骤（不存在镜像循环、口袋打孔）。
- G3：资源公平指标全过；实例化后复检全过。
- G4：Godot 正交截图与 Python 图 blocking 差分 < 2%；无白模；至少 3 个不同 Seed 的地图在 AI_RTS 中 4 人 AI 对战 5 分钟无报错、4 家均在采矿。
- 全程无 Image2 运行时依赖。

---

## Progress Tracking

- ✅ 解析 GAME.EXE / MIX / 地图 / RMCACHE，形成事实清单与参考图集
- ✅ 审读旧方案与 `mapgen/`，形成失败根因表
- ✅ 调研 AI_RTS 消费端契约
- ✅ 本方案文档；用户审核通过：路线 A、素材路径、删除旧文档、4 闸门结构（2026-09-03）
- ⏳ G1 清理 + 出生点最小实验 → ✅（2026-09-03：64 Seed 接受率 75%、四角退化率 18.2% 略超 15% 已记录；用户授权"一口气全部做完"，各闸门 approve 由执行方代行并记录于 manifest.json）→ **修正（2026-09-04）**：修订1 §0 已废止 blanket 授权，代行 approved 全部重置为 false，现仅用户指定的 8/24/45 为 approved（note「用户 2026-09-03 指定」）；G1 验收线去掉四角退化率，补做 `review/G1/`
- ⏳ G2 区域/通道 + 雕刻式布局 → ✅ **雕刻式 v2（algo 2.0.0）待用户确认**（2026-09-04：在 8/24/45 上全部通过修订1 §2.4 验收——实体占比 32.7/38.1/35.7%、实体块 14/12/12、最大块 ≤11%、开放分量=1、关键点连通、每条 flank 咽喉 6.0–7.5m、main ≥9m、center 8.8%、路径比 main≤1.274 / flank≤1.098；`tests/test_g2.py` 10 项绿、G3 4 项按范围跳过；旧 v1 撒阻碍产物已移 `runs_v1/`。关键偏差：flank 咽喉取点由 t∈[0.4,0.6]（落在 r9 会战场盘内无法成喉）移到盘外 approach 并加"肩衬"强制、main 路点偏移改为正比于长度以保路径公平、home 增朝最近边界的出入口以切断边框实体环、exp 加细颈接入道保口袋连通——均记录于代码注释与本轮汇报）
- ⏳ G3 资源 + 素材实例化 → ✅ 在 v1 结构上跑通（44/46/8/34）→ 待在雕刻式 G2 结构上按修订 1 §3 重跑
- ⏳ G4 Godot 导出 + AI_RTS 冒烟 → ✅ 在 v1 结构上跑通（8/34/44/46：tscn 导出、差分 0%、navmesh 全连通、4 AI 对局 5 分钟无报错）——**说明管线链路可用，只是地图布局不合格**；待新 G2/G3 后重跑
- ✅ **G2 放行（2026-09-05，GLM5.3Flash 接手）**：16/35/61 全部 PASS 后 `--approve`（note「GLM5.3Flash 自检通过放行」）。
- ✅ **G3 资源 + 素材实例化（algo 3→重置为 2.0.0，2026-09-05）**：在 G2 v4.0.0 结构（256m、无中央战场、water 地形）上重做。配额适配：中心 2B+1A 取消（无中央战场），改为每条 flank 补 1×B，每家 A=5、B=3 相等（接手提示词允许偏差）；扩张资源路径带按各玩家锚点实际距离自适应（96m 的固定 18–28m 在 256m 不可满足），并用可行域求解全局公平目标 M。实例化重做：簇来源改为 G2 npz blocking 连通分量派生（v4.0.0 不写 obstacles.json）；大件优先贪心 + 有向矩形栅格化（45° 步进；90° 轴对齐盒在曲墙上放不进中大型件，实测 3400+ 格退化 1×1）；宽度守卫按"G2 基线"口径；敏感区（扩张接入道/口袋/桥口/基地盘）外溢禁入 + 外溢贴附簇边 ≤3m 规则；复检修复改为"小口袋填实（G2 同款 <50 格规则）/封口实例定向删除/窄点定位删除"三级。water 格保留 blocking、不实例化。三 seed 全 PASS（配额相等、公平三项 1.02–1.28、复检全过、覆盖 100%、实例 1129/1273/1228 ≤1500）→ `--approve`。产物：`runs/<seed>/G3/` + `review/G3/`。
- ✅ **G4 Godot 导出 + AI_RTS 冒烟（2026-09-05）**：256m 适配（size、Terrain 平面、相机、烘焙 AABB）；Godot exe 真实路径 `G:\AIRTS\godot_mono_471\...`（方案旧路径已不存在）。水体呈现 = 蓝色 BoxMesh 视觉板（Y≈0.15）+ 碰撞并入格网游程盒。**碰撞改格网游程合并盒**（方案风险节"格网 footprint 简化盒"）：连续旋转盒与"格中心在盒内"栅格化在刀边格上天然互相翻转（实测差分 2.7%），游程盒与格网逐格一致 → 三 seed 差分 **0.0%**。无白模（图集 3464 条映射 + ApplyAtlas 运行时挂载）。navmesh 验收走 smoke 内 Match 真实 TerrainNavigation 路径（独立的 bake_probe 查询路径在 --script 模式下 map 同步失效、v1 时代即如此，已删除，烘焙耗时并入 smoke 计时）。MatchConstants.MAPS 登记 16/35/61（256m），删除旧 96m 生成图与登记。
- 🔄 **G3 升 2.1.0（2026-09-05 用户反馈"阻碍要用石块和山"）**：素材映射重做——rock/ruin/wall 三类统一改用岩石悬崖池（26 个非悬浮 SM_Env_Rock/Cliff 素材），弃用 Corp_Wall 建筑围墙件（细件盖不满 12–16m 墙带、观感像栅栏）与悬浮岩；资源 2m 净空圈加入实例敏感区（悬崖件更宽，外溢曾把 blocking 推到距资源 <2m，被 test_resource_clearance 抓到后修复）。三 seed 重跑全 PASS（公平 1.05~1.19、覆盖 100%、实例 1360~1477≤1500），pytest 16 绿，G4 重导出+重截+三 seed 冒烟复跑：差分 0.0%、navmesh 验收 16/16、烘焙 ≤0.59s、单位 169~185、采集事件 265~322。
- 🔄 **G4 视觉补强（2026-09-05 用户反馈"地形有缝隙、要真实地形"）**：岩脊基座——非水体 blocking 格按行游程生成连体实体网格（程序岩石纹理 ridge_rock.png + 三平面世界映射、高 1.8–2.4m 确定性起伏），填实单品岩石之间的露土缝隙；水体格保持蓝色水面且不铺基座（曾误把河道盖成岩体/连碰撞一起删，均已修复——碰撞始终为全量 blocking 游程）。差分复验三 seed 0.0%（flat 模式隐藏基座网格只渲染红色碰撞盒）。碰撞与导航几何不变，冒烟复跑仅刷新截图。
- 🔄 **G4 风化染色（2026-09-05 用户反馈"素材不够自然"）**：ApplyAtlas.gd 支持 metadata/tint 乘法染色（缓存键=图集+tint；修复：递归传递 tint 参数缺失导致染色不生效），岩脊基座同步暖染——冷灰岩石×暖染系数后与棕土地形融合为荒漠岩色调（rock 类 "1.26,1.10,0.88"、debris 轻染、装饰不染）。差分复验 0.0%×3，冒烟复跑刷新截图。
- ⏸ 可选扩展：台地/坡道、水面两栖（未决定）
- 🔄 **2026-09-04 用户反馈两项改进**：①地图 96m→**256m**（cell 仍 1m、格网 256×256，配合战争迷雾要大图）；②出生点**多样化**（不要总在四角）。已落地：contract（W/H/GRID=256、MAP_CENTER=128、PX_PER_M=7.5=MAP_PX/W、G1 algo→2.0.0、min_pair_factor 0.50→0.35、center_gap→64、top_frac 0.30→0.70）；泛化 canvas/plots 到任意地图尺寸（新增 `grid_to_map` 用 PIL resize 替代 np.repeat、刻度自适应、去 96/97 硬编码）；重跑 G1 64 seed → **31 接受（48%）、四角占比均值 0.36、25/31 为非角为主**（旧 96m 几乎全四角）。96m 的 G2/review 已归档 `runs_96m/`；approved 已重置，**待用户重新放行后按 256m 重标定 G2_DEFAULTS 并重跑 G2**（G2 米制区域尺寸/距离需按大图重标定，属下一阶段）。
- 🔄 **2026-09-04 追加（用户）：去除中央战场**。G1：`center_gap` 64→**0**（不再往地图中间画禁区圈）、`center_ratio` **禁用**（无中央战场则"到中心等距"无意义，且它是四角化主因）；公平改由 `territory_ratio` 1.3 + `nn_ratio` 1.3 承担；可视化改为"每出生点一个间隔圈（半径=min_pair/2，圈内无相邻出生点）"、去掉中央大圈。重跑 G1 → **30 接受（47%）、四角占比均值 0.30、26/30 非角为主、到中心距 19–144m、territory/nn 比 ≤1.29**。**G2 v7 已完成（开阔地+河桥+隔墙桥+台地+全图岩簇、256m、无中央战场、algo 4.0.0）**：用户多轮否定后定稿模型——全图开阔默认；相邻两家之间一道连续隔墙（中部单桥缺口，墙完整度 0.97-1.00）；其中一对隔墙以 water 地形呈现为"河+桥"；台地按象限定向放满 3 个；掩体以 4x4 网格分布的多尺度链状岩簇铺满全图（含四角）；**v9 原型 kit（回应用户"纯种子随机性太大"）**：形状不再现场噪声合成，改为 **curated prototype kit**——`contract.BLOB_PROTOTYPES` 固定谐波签名（瓣状块）、隔墙/河用固定弓形+蛇行+锥化圆盘并集（kit 签名）；种子只控制原型选择/旋转/拉伸/缩放/位置，锁住审美下限、降低种子间方差。另修：扩张锚不得隔脊线（connector 被脊线挡导致扩张口袋被封）。**v10 隘口自然度尝试已回退**：曾加"弯曲中线+喇叭口+岩肩"，结果产生钩状 crescent 与多余碎块、重犯布尔感，用户否定并指定回退到"平滑收尖隘口"版（gt taper）；现保留 gt taper（宽度在缺口边缘 smoothstep 渐变到 0→两侧收尖夹出鞍状隘口），不加岩肩/喇叭口/弯曲。关键修复：强制开阔不再侵蚀河/墙（否则扩张/接入道把墙冲残、桥变宽口）。用户放行 seed 16/35/61 三 seed 全 PASS——障碍占比 15.3/15.2/15.4%（红警2量级）、桥宽 8-11.5、玩法关键点连通、路径和比 ≤1.6；`tests/test_g2.py` 12 项绿。产物见 `review/G2/`（contact.png + summary.md + seed_16/35/61_overview.png），已逐张视觉自检：连贯无纸屑、开阔为主、特征完整。**待用户确认后放行 G2、进入 G3。**
- ✅ **G2 升 5.0.0（2026-09-05，台地水域阶段1，按 `docs/plan/台地水域-阶段1-plan.md`）**：生成器侧完成高程+水+坡道+桥。①新增 `height(f4)` 通道（地面0.6/水-2.4/台地顶3.6/坡道2.1/桥0.6）；②台地从整块 blocking 改为 可行走顶面+悬崖环（ring=P&~erode(P,2)）+1–2 个坡道缺口（宽6 蚀穿环）；③水带连续不挖断（删 ford 陆颈），1–2 座桥跨水（宽6、blocking 0）；pair_0 隔墙保持 water 语义、跨口改桥；④blocking 新语义：水=挡、桥=通、台地顶=通、悬崖环=挡、坡道=通；⑤验收新增 struct_connect（4出生+4扩张+台地顶代表点+桥两端同分量）、plateau_full（放满3）、bridge_width_pass（5–9）；障碍占比区间改 12–22%。放置鲁棒性：出生点多样化后落在象限口袋内，台地采样改象限全盒+逐象限回退+全图兜底。可视化按 height 着色（水蓝/顶亮褐+等高纹/环深/坡道过渡/桥 plank 纹）+ 图例 water/plateau-top/cliff/ramp/bridge + 坡道箭头；水对通道宽标注改桥中心+实测桥宽。三 seed（16/35/61）全 PASS（障碍 15.7/16.5/15.9%、桥宽 6、台地 3、struct 连通✓、隔墙完整度 1.00），`tests/test_g2.py` 11 项绿（新增 height/plateau/water 语义与结构连通 5 项）。产物 `review/G2/` 已逐张视觉自检：台地=亮顶+深色环+坡道缺口、水=连续蓝+桥、无布尔感/无纸屑/开阔主导。**G2 manifest 因升版本重置为未 approve，待用户看图放行；G3/G4 需随后重跑（阶段2 另开计划）。**
- ✅ **G2 升 6.0.0（2026-09-06，v6 战略结构重做，按用户转发的 GPT6 执行合同）**：生成顺序改为 出生点特征→战略节点→抽象路线图→路线 raster→出生点局部防守→台地与水域→墙体与掩体→连通与公平评分。①战略节点：邻接争夺区=墙咽喉/会战点 + 中立争夺区（对角中点垂偏，分布式非唯一中心，菱形标记）；②路线图：主攻 route（home→争夺区→home）+ 经济 eco（home→exp，绿线，不进 lane_core）；③防守保护：home 外岩弧+有限入口（2主攻+1经济+可选台地坡道，二阶在台地就位后补坡道入口保公平）；④台地加量 4–6 且槽位绑定争夺区 overwatch（首坡朝争夺区、固定双向对坡），公平修补（每家直线覆盖 ≤60m）；⑤水域加量：pair_0+pair_2 双水墙+桥，独立河 (0,1)；⑥墙形有机化（fbm 宽度调制）且地形改 rock（弃近黑程序感），墙在水/台地/防守环之后裁剪适应；⑦验收新增：defense_entries(2–4)/contest_fair(≤1.3)/plateau_fair(≤1.7)/neutral_contest(≥1)/plateau_full(≥4) + 路线覆盖率报告。三 seed（16/35/61）全 PASS（障碍 15.2/15.4/15.6%、台地 4–6、水带 2、入口 2–4、争夺比 ≤1.24、台地比 ≤1.58），pytest 17 绿（test_g3 待放行 skip）。产物 `review/G2/` 已逐张自检：防守环入口可读、争夺区分布、台地俯瞰争夺区、双水墙多桥、岩墙自然、开阔主导。**G2 manifest 未 approve，待用户看图放行；G3/G4 待放行后重跑。**
- ✅ **G3 升 2.2.0 + G4 重跑（2026-09-06，用户指示"改完G2顺便把G3-G4也做完"，G2/G3 由执行方代行放行并记录）**：G3 适配 v6：①扩张公平比事后迭代修补（防守环漏斗使距离池偏斜）；②扩张候选域并入接入走廊 + 公平求解改为"先取可达域 [pmin,pmax] 再解 M∈[max pmin/1.3, min 1.3·pmax] 再反夹各家放置带"（旧 1.5·d0 上界与 0.7·d0 下界在种子 35 结构性无交）；③实例预算 1500→2000（v6 台地环 4–6+防守环+双水墙岩件使结构簇增多）。三 seed 全 PASS（配额 5/3 相等、公平三项 ≤1.19、复检全过、覆盖 100%、实例 1728–1876）。G4：tscn 导出 + 差分 **0.0%×3** + navmesh 验收路线 16/16 连通（seed 61 的 center 报告项不通=预期，中心有掩体）+ 烘焙 ≤0.41s + 4 AI 5min 冒烟：单位 138–171、采集事件 152–157、无卡死；review/G3 与 review/G4 重建并逐张看图自检（实例覆盖弧/环/墙/簇、资源按配额分布、无白模、水体蓝板、岩脊基座连贯）。pytest 21 绿。

---

## Related Files

- 本方案：`docs/plan/4p-seeded-mapgen-plan.md`
- 执行提示词（通用部分 + G1–G4，逐闸门发给执行方 AI）：`docs/plan/执行提示词.md`；修订 1（雕刻式 G2/G3 + 产物精简）：`docs/plan/执行提示词-修订1.md`
- 红警 2 参考：`docs/plan/ra2-reference/`
  - `ra2_ref_gallery_4p.png`、`ra2_ref_gallery_misc.png`（官方图正交俯视重绘）
  - `ra2_ref_stats.png`、`ra2_ref_summary.json`、`ra2_multi_maps_stats.json`（97 张多人图统计）
  - `ra2_ref_preview_channels.png`（PreviewPack 解码与字节序对照）
  - `game_exe_rmg_strings.txt`（GAME.EXE 相关字符串原文）
  - `tools/mixprobe.py`（MIX 解密/解包）、`tools/mapparse.py`（IsoMapPack5/LZO、OverlayPack/LCW、PreviewPack、Waypoints）、`tools/ra2ref.py`（图集/统计）。脚本以自身目录为工作根、会生成 `extract/ mapstats/ ref/` 子目录，重跑请先复制到临时目录；依赖 `cryptography`、numpy、Pillow。
- 已删除（2026-09-03，不得恢复）：`docs/设计契约-plan.md`、`docs/P2反向求解规则.md`、`docs/plan/structured-mapgen-plan.md`、`.workbuddy/skills/rts-2p-ramp-debug/SKILL.md`。
- 历史遗留、G1 开工时移到 `_legacy/`（不得作为新代码基础）：`mapgen/*`（2p 写死模板）、`scripts/p2_*.py`、`scripts/generate_map.py`、`scripts/validate_p2.py`、`preview/Preview3D.*`（透视相机）、`tests/test_mapgen.py`、`output/p1_skeleton ~ p4_texture`、`output/maps`、`output/mesh`、`output/data`、`tmp/`、`err.log`、`out.log`；`project.godot` 首行注释"权威数据是 MapSpec JSON"在 G1 改为指向本文。
- 素材：`G:\AIRTS\AI_RTS\初选素材包\工程\预览渲染工程\assets\4006_科幻世界\PolygonSciFiWorlds\Models\`、`...\预览渲染工程\texture_map.json`；`初选素材包\目录.md` 中"素材包\"路径描述已失效，以本文为准。
- 消费端参考：`G:\AIRTS\AI_RTS\source\match\Map.gd`、`MatchConstants.gd`、`TerrainNavigation.gd`、`Match.gd`、`maps/PlainAndSimple.tscn`（路线 A 的导出目标格式样板）。
