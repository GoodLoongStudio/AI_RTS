# GLM_TO_QWEN — GLM5.3 Flash 视觉执行轮交接报告（2026-09-06 晚）

> 上一轮（接手核对）报告见 `GLM_TO_QWEN_round1_handoff_check.md`。本轮=视觉执行与四类缺陷修复轮。
> **对齐声明**：目标=处理大面积单色地面、黑色锯齿岸线、巨大白色岩件、机械散布小装饰四类缺陷，让高台/坡道/河桥/湖岸自然协调且保持战术可读性。允许修改范围=`visual.py`、`visual_profiles/*.json`、`GeneratedTerrain.gd`（材质/运行时部分）、`handoff/` 交付文档、`tmp_logs/` 诊断工程。越界改动两处（g4_export.py 一行、pipeline.py 三处）已在 ISSUES.md I11/I12 透明标注，请复核收编。

## 状态：READY_FOR_INTEGRATION_CHECK（视觉交付完成；可玩性有一项硬阻塞，见第四节）

## 一、四类视觉缺陷处置结果（三张基准图全部重建验证）

| 缺陷 | 根因 | 处置 | 验证 |
|---|---|---|---|
| ① 大面积单色地面 | 原着色器近似纯色 | shader v2：宏观 fbm 色斑 + 台地顶草原斑块 + 细噪声 + 按亮度归一的 terrain_albedo 全局 tint | 16-0 v6 正交图：暖沙色带自然斑驳 |
| ② 黑色锯齿岸线 | GL 兼容下水缘陡壁格子掠射角不被光栅化（I8），透出 Map.tscn 的 Y=-0.1 黑垫板 | `GeneratedTerrain.gd` 运行时隐藏 `BlackBackgroundFixingAntiAliasingBug`（A/B 实验胜过补缝平面案，详见 I9） | 47-0 v3 同位扫描线黑像素 10-11px→**0**；全图近纯黑仅剩 93px（素材暗部） |
| ③ 巨大白色岩件 | 4006 灰白崖件大尺寸率高 | 4041 暖色系受控入池（cliff 13 项）+ `large_chance=0` + 缩放收紧 [0.5,0.85] + spacing [14,26] + budget 60 | 三图崖环呈暖棕点缀，无巨型白岩 |
| ④ 机械散布小装饰 | 均匀随机 + 异色素材混入 | 预算 380→210 + 簇心 60% 概率偏置崖脚 + 簇参数 profile 化 + 剔除红植/青灌/黑刺/科技件 | 三图散布成簇、色系统一暖调 |

## 二、修改文件清单（Qwen 集成复验输入）

**允许范围内：**
- `rtsmap/data/godot_scripts/GeneratedTerrain.gd`：着色器 v2（cull_disabled + FRONT_FACING 法线翻转 + 色带/色斑/斑驳）；`_hide_redundant_ground_plates()` 隐藏 GroundMesh* 与黑垫板（含 I9 注释）
- `rtsmap/presentation/visual.py`：`visual_assets_extra.json` 受控索引 + `use_extra_assets` 门控（default 样式 100% 4006 保契约）；条目级 scale_range；散布聚簇（cluster_radius_m/cluster_size/edge_cluster_ratio）；四处池清理（`_plant_pool` 只留 Plant_Small/Cactus；`_scatter_pool` 剔 Greeble/Fern/Flower）
- `rtsmap/data/visual_assets_extra.json`：新建，23 条 4041 实测条目（cliff 13/shore 5/shore_veg 6/scatter 10），含 res_path/atlas/size/min_y/pools/scale_range
- `rtsmap/data/visual_profiles/natural.json`：v2.1.0-natural（use_extra_assets=true；budget_total 450=cliff 60+shore 120+scatter 210+余量；tint/terrain_albedo 暖调）

**越界（透明标注，请复核收编，详见 ISSUES.md）：**
- `rtsmap/gates/g4_export.py` line 401：Visual 节点补 `type="Node3D"`（修复 423 视觉实例被丢弃）
- `rtsmap/workbench/pipeline.py` 三处：rebuild_visual 引擎阶段 visual_profile 保持（Codex F3 同源修复）

## 三、素材与依赖

- 新增依赖：4041 包 23 个 FBX + 图集 `WesternFrontier Texture_01_A`（已在 `AI_RTS/assets/models/scifi-worlds/4041_*/`，含 .import）；无其他新增。
- 混包纪律：4006/4041 原生尺度差 2–3×，逐包标定（见 `asset-candidates.json`）；单图集不跨包。

## 四、验证结果（如实记录，不含美化）

| 项 | 结果 |
|---|---|
| 契约测试 `pytest tests/test_visual_api.py` | **4 passed**（最新池改动后回归） |
| 16-0 v6 nav_check | **all_pass=true**；充分等待仲裁探针复核：坡道 13/13 通 + 跨图 6/6 通 → **真 pass** |
| 35-0 v3 nav_check | **all_pass=true**；同法复核：坡道 13/13 通 + 跨图 6/6 通 → **真 pass** |
| 47-0 v3 nav_check | **all_pass=false**；同法复核：坡道 **0/11 全断**（gap≈坡道全长，斜面在 navmesh 中整段缺失；Terrain region 仅 2218 polys vs 35-0 3080/16-0 2462）→ **47-0 不可实战，阻塞项，见 I7** |
| 实战（smoke/对局） | **未验证**——不能以截图代替可玩性 |
| 参考视频 | **未核对**（小红书拉取失败两次：总控 300011、GLM 侧需登录 token）——`reference_alignment=not_verified` 保持，色调依据 03 文档文字目标与本地核验 |
| Forward+ 表现 | **已复测（Vulkan 1.4.341）**：修复前黑岸线在 Forward+ 下同样存在（非 GL 特有，实战可见）；修复后同样消失——**黑垫板隐藏在两个渲染后端下均必要且有效**，I9 关闭 |

## 五、三图交付与 review 索引（同任务同版本，seed 全部 20260906）

| 图 | job_id | 版本 | profile | 正交 | 局部 | 前后对照 |
|---|---|---|---|---|---|---|
| 16-0（无水台地） | bf4fbbf72daa472fa1bd2403a94c383e | v6 | natural 2.1.0 | ✓ | plateau_gate/plateau_ring + 斜视 gate | full + plateau_gate（before=v5） |
| 35-0（河+桥） | f61365bbb11049f0afd2aa1fc9477445 | v3 | natural 2.1.0 | ✓ | bridge_mid/river_bank/plateau_gate + 斜视 bridge/gate | full + bridge_mid（before=v2） |
| 47-0（河+双湖） | f851a0dd6f1b4863b7833f6c5cac25f9 | v3 | natural 2.1.0 | ✓ | bridge_river/lake_shore/plateau_gate + 斜视 bridge/lake | full + bridge_river（before=v2） |

全部位于 `review/G4/workbench/<job_id>/`（sync 工具已刷新 index.html）；上轮 v2 旧局部图移入各 job `archive_visual_v2/` 保留为历史。例证：47-0 岸线对照（BEFORE 左下黑块 → AFTER 干净）见 `47-0_before_after_bridge_river.png`。

**已知观感残留（G3 层，保护文件，GLM 不可改）**：红色异形植物/紫晶体/科技残骸/灰白崩壁环仍在（见 `47-0_obl_lake_shore.png`），已开 I10。

## 六、待 Qwen 事项（优先级序）

1. **I7 47-0 坡道 navmesh 断裂**（可玩性硬阻塞；**根因已定位**：坡道 carve 插值错位——前 9.5m 全平+中段两级 ~1.1m 台阶，且 heightfield_report 的崖壁豁免把台阶误判为合法崖坎致自检漏报；详见 ISSUES.md#I7，修 g4_terrain carve + report 豁免两处）
2. I6 nav_check 空图假收敛根治（本次 16-0/35-0 的 pass 也建议用长等待复跑确认）
3. I11/I12 两处 GLM 越界修复复核收编
4. I10 G3 装饰资产表调整（已附量化清单：47-0 层内 49% 为科技残骸/木箱/红植/青灌/Greeble，Rock_08 单款 448 个；详见 ISSUES.md#I10）
5. I8 掠射角渲染缺陷（可延后，仅影响诊断链路）
6. ~~I9 Forward+ 下黑垫板必要性验证~~（已完成：两后端均必要且有效，见第四节）——请在真实对局顺带确认地图边界观感

## 七、诚实声明

- 本轮所有「改后」图均为 rebuild 后真实引擎 GL 兼容渲染输出；对照图为左右/上下拼接（两侧同等对待，无像素修饰）。
- 未动玩法数据、未缩水域、未用 PNG 美化验收结果；工作区未提交未推送（按指令保留）。
- 47-0 当前不可实战；16-0/35-0 的 nav_check pass 属工具链当前口径，实战仍未验证。
