# ISSUES — GLM5.3 Flash 接手核对记录（2026-09-06）

记录人：GLM5.3 Flash（视觉/素材方）。依据 `02-GLM5.3Flash.md` 第一节：交接缺失时写清具体缺失到本文件，可继续只读素材研究并建立候选清单，**不擅自重写导出器、height、G2 或导航**。本轮 GLM 未修改 `rtsmap/`、`tests/`、游戏侧任何工程文件；只新增了本 `handoff/` 下文档与 `tmp_logs/glm_measure_4041/` 隔离测量工程。

## I1 交接包整体缺失（阻塞，责任：Qwen）

- 现象：`docs/plan/workbench-team/handoff/` 目录不存在。`QWEN_TO_GLM.md`、`handoff.json`、`visual-api.md`、`baseline-metrics.json`、`file-state.json`、`requirements-checklist.json` 六项全部缺失。
- 重现：`find G:/AIRTS -maxdepth 4 -name "QWEN_TO_GLM*" -o -name "handoff.json" -o -name "visual-api*" -o -name "requirements-checklist*"` → 零命中（2026-09-06 17:30 实测）。
- 影响：状态不是 `READY_FOR_VISUAL`，V0「接手复现」无法执行；`01-Qwen3.8Max.md` 第六节完成门槛未达成。GLM 无法开始冻结接口上的视觉工作。
- 建议：Qwen 按 `00-总控与交接.md` 模板补齐六件套；`file-state.json` 记录实际文件状态（工作区有大量未跟踪/已删除文件，勿只写 HEAD）。

## I2 视觉接口未实现（阻塞，责任：Qwen）

- 现象：`rtsmap/presentation/`、`rtsmap/data/visual_profiles/` 不存在；`grep -rniE "presentation|visual_plan|visual_seed|visual_profile" rtsmap/ tests/` → 零命中。
- 影响：`01-Qwen3.8Max.md` 第五节 10 条接口义务（build_visual_plan、固定地图重建视觉、契约测试、固定镜头截图等）未开始。GLM 没有任何可写入口。
- 建议：先交付可运行默认实现 + 至少 1 个样式示例在 3 张基准图上跑过，再冻结接口。

## I3 G4 仍是旧平面导出，无真实几何（阻塞，责任：Qwen）

- 现象：`rtsmap/gates/g4_export.py` 自述「当前G4只导出统一平面、障碍盒、水体板」；地面为单 PlaneMesh + `uv1_scale=0.16`，水体为蓝色 BoxMesh 视觉板。游戏侧 `AI_RTS/source/match/maps/generated/` 仍只有 `seed_16/35/61.tscn`（按 G1 seed 命名的旧产物，唯一任务/地图 ID 改造未落地）。
- 影响：无「改后」可拍，前后对比不成立；R01/R04/R10 无法进入视觉轮。
- 建议：按 01 文档第三节 C 实现真实台地/坡面/桥面/水域几何后再交视觉。

## I4 G2 仍在迭代且未全绿（阻塞，责任：Qwen）

- 现象：最新工作台任务 `workbench_output/cfb60de75bbe4ba8825c70c422c2f3e7/`（2026-09-06 16:49，algo 7.4.0，`preview_only: true`）：`all_pass=false`，选中 attempt 3 仍有 `open_single_pass`、`plateau_strategy_pass` 两项失败；16 次尝试全部含失败项。
- 影响：视觉基线结构未冻结，V1「固定第一张图」无从固定；现在做的任何视觉都会因 G2 继续改动而返工。
- 建议：Qwen 先把大湖/河湖组合修到全绿并出三张基线（覆盖无水/有河桥/有湖），再冻结。

## I5 参考视频未核对（保持 not_verified，双方共同）

- `03-视觉目标与素材索引.md` 记录总控本轮访问失败（300011）。GLM 同样未播放该视频。`reference_alignment=not_verified` 保持；本轮全部依据本地截图与已明确目标，未假设视频色调/题材。

## GLM 本轮已完成的无依赖工作（Qwen 可直接复用）

1. **素材候选池**：`handoff/asset-candidates.json`。4006 主选 33 项 + 4041 暖色备选 30 项，含源路径、Godot 映射、图集、尺寸、原点（min_y）、预览、用途、允许缩放/旋转、贴附面、禁用清单。
2. **4041 尺寸实测**：30 个候选 FBX 经 Godot 4.7.1 headless 真实导入测合并 AABB（隔离工程 `tmp_logs/glm_measure_4041/`，源素材只读拷贝）。**两包原生尺度差约 2–3×**（如 4006 Cliff_Flat_01 宽 31.4m vs 4041 Quarry_Wall_Straight_01 宽 15.1m），混包必须逐包标定缩放，不能共用统一 scale 系数。
3. **关键集成事实**：4006 崖件 min_y 达 -3.3~-25.9（原点在模型上部，直接 y=0 摆放会沉底）；4041 崖壁 min_y≈-0.2~-0.7（近底原点）。视觉接口必须支持按 min_y×scale 的 y 偏移规则。
4. 现有 `terrain_to_assets.json` 岩石池（SM_Env_Cliff_*/SM_Env_Rock_* 共 26 件）与 `assets_catalog.json`（1144 条，含 size/min_y/atlas）可用作接口输入，无需重建。

---

# 视觉执行轮新增问题（2026-09-06 晚，GLM5.3 Flash 记录）

> 以下为 GLM 视觉执行期间发现/修复的工程问题。凡 GLM 已动手的修复均逐条透明标注（含越界文件与行级改动），请 Qwen 复核并决定是否收编。

## I6 nav_check 探测循环时序缺陷（责任：Qwen，工具层）

- 现象：v3 时代（default/natural 场景 A/B 均）52/52 路径全失败；`nav_check.gd` 用 `map_get_closest_point(first_target)` 探测 bake 收敛，**空导航图上该 API 返回查询点本身 → 距离 0 < 25 → 立即 break**，`bake_wait` 记录 0.26–0.35s 形同虚设，路径检查跑在异步烘焙完成前。
- 证据：`tmp_logs/glm_visual/nav_deep_probe.gd`（等 300 物理帧后 Terrain region 1990 polys、in_map=true、coverage 正常）——烘焙本身完好。
- 现状：最新一轮 rebuild 后 16-0/35-0 报 all_pass=true、47-0 all_pass=false，说明检测逻辑在 bake 已完成时**有甄别力**；但「空图假收敛」缺陷未根治，结果稳定性仍取决于机器时序。
- 建议：改用 `NavigationServer3D.map_get_iteration_id()` 或轮询 region polys>0 作为收敛判据；`bake_wait` 改为有界长等待。

## I7 47-0 坡道 navmesh 真实不连通（阻塞可玩性，责任：Qwen，G4 几何域）⚠ 本轮最重要

- 现象：47-0 最新 nav_check（rebuild v3 后）`all_pass=false`：**全部 12 条 ramp bottom→top 断**（路径走 8–9m 停在离坡顶 7–8m 处）、P0→P1 / P0→P3 / P2→P3 断（end_dxy 28–30m）、P1→res_10/11、P3→res_14/15 断；**三座桥全通、平地路径全通、出生点近矿全通**。
- 仲裁：`tmp_logs/glm_visual/nav_47_ramp_probe.gd`（等待 360 物理帧确保 bake 完成后）`map_get_path` 查 ramp_0_0 bottom(172.09,0.6,197.16)→top(162.45,3.6,209.93)：路径 5 点，**终点 (166.8, 1.5, 204.0) 卡在坡道中部 y≈1.5**，离目标 7m；反向同样断。**不是时序假失败，是坡道面与台地顶 navmesh 真实裂缝**。
- 三图真值复核（`nav_triple_probe.gd`，同法充分等待后按 nav_check.json 检查点全量重验）：**16-0 坡道 13/13 通 + 跨图 6/6 通；35-0 坡道 13/13 通 + 跨图 6/6 通（两图 nav_check pass 为真）；47-0 坡道 0/11 全断**（gap 7.3–8.7m ≈ 坡道全长，末点 y 1.2–1.5 且坐标网格对齐）+ 跨图 1/5。断点模式指向 **47-0 坡道斜面在 navmesh 中整段缺失**（非接缝小裂）；且 47-0 Terrain region 仅 2218 polys（35-0 3080 / 16-0 2462）。
- **根因已定位（height_data.bin 剖面实测，两图各 257×257 cell=1.0m）**：ramp_0_0（bottom 172.09,197.16 → top 162.45,209.93，线长 16.0m）沿坡道中线高度剖面为——0–9.5m 恒 0.60（平地！）、9.5m 处 **+1.04m 台阶**、10.5m 处 **+1.12m 台阶**、之后才缓爬到 3.60。而 export 参数 `ramp_run_m=15.0`，应为 15m 均匀斜坡（每米 +0.2m）。**坡道 carve 的高度插值错位：前段全平 + 中段两级 >1m 垂直台阶**，违反 agent_max_climb=0 与 ≤1.0m 步高约束 → navmesh 烘焙在台阶处断开（断点 y≈1.2–1.5 与台阶位置吻合）。
- **自检为何没拦住**：export.json `heightfield_report` 报 `max_step_walkable_m=0.525 / walkable_slope_step_ok=true`，但台阶真实存在——报告的崖壁豁免掩码（`_cliff_edge_mask`）把坡道上的台阶边**误归类为合法崖坎**，walkable 统计漏检。两处需同修：①`g4_terrain` 坡道 carve 插值（16-0/35-0 同参数坡道剖面正常，可对照其 carve 实现）；②`heightfield_report` 对坡道区域禁用崖壁豁免（坡道线上的边必须按可走边校验）。
- 含义：47-0 单位上不了台地（=上不了 P1/P3 出生点、中央台地矿）——**该图当前不可实战**。视觉材料再好看也不能替代此项通过。
- 建议：Qwen 检查 g4 坡道 carve 段的静态碰撞 trimesh 连续性 / navmesh 烘焙 filter（agent_max_climb=0 下坡道面必须与两侧地面共享边）。16-0/35-0 同链路 pass，可对照其坡道几何差异定位。

## I8 GL 兼容渲染：地形网格掠射角不渲染（责任：Qwen/引擎层）

- 现象：全图斜视（透视掠射角）下地形网格整片不渲染——**用红色无光照 StandardMaterial3D 强制替换地形材质后地形仍整体消失**（道具正常渲染），正交俯视正常；`near=1.5` 无改善（排除深度精度）。
- 复现：`tmp_logs/glm_visual/glm_oblique_capture.gd --terrain-red --only-terrain`，产物 `tmp_logs/glm_visual/exp_red.png` 等 exp 系列。
- 影响：仅诊断链路（交付正交图+局部斜视不受影响）；Forward+ 未复测。
- 建议：向引擎层排查 GL 兼容下掠射角背面/法线剔除行为；或交付链路统一正交。

## I9 BlackBackgroundFixingAntiAliasingBug 黑底板副作用 —— GLM 已修，请复核

- 现象：Map.tscn 自带 Y=-0.1 全图黑垫板。GL 兼容下（叠加 I8）顶视透出水缘一圈 ~1.3m 纯黑锯齿边（像素取证：水蓝→纯黑10-11px→沙；阶梯步进=高度场格子边界）。
- GLM 修复：`GeneratedTerrain.gd`（允许文件）`_hide_redundant_ground_plates()` 内隐藏该节点；A/B 实验对比过「隐藏黑底板」vs「加水下补缝平面」两案，前者干净胜出（后者因水面半透明被垫亮过曝）。修复后 47-0 v3 同扫描线黑像素 0、全图近纯黑 93 px（素材正常暗部）。
- Forward+ 复测（`shore_fix_experiment.gd` RAW_unhide vs baseline，Vulkan 1.4.341 / RTX 3080 Ti）：**还原修复前（垫板可见）时 Forward+ 下黑岸线同样存在**——黑线并非 GL 兼容特有，实战也会出现；**修复后（垫板隐藏）Forward+ 黑线同样消失**。结论：该修复在两个渲染后端下均必要且有效，无渲染后端门控必要。（注：诊断脚本光照环境与真实游戏 WorldEnvironment 不同，但黑线存在/消失判断不受影响；垫板原名所修的「边界 AA bug」在隐藏后未复现，建议 Qwen 在真实对局中顺带确认地图边界观感。）

## I10 G3 装饰层观感污染（责任：Qwen，g3_content 保护文件，GLM 不可改）

- 证据：`review/G4/workbench/f851a0dd.../47-0_obl_lake_shore.png`、`f61365.../35-0_obl_bridge_mid.png`（真实引擎局部斜视）。
- 问题：①红色异形植物（Fern/Flower 系）与暖沙地形强冲突；②紫色晶体、青蓝灌木冷色突兀；③科技残骸（Greeble/Scav/Crate）与自然题材不符；④崩壁环灰白岩连续排列呈「城墙」感且是灰白色（与 4041 暖色崖件不协调）。GLM 视觉层已剔除上述类别自家池子并减预算，但 G3 层原样保留。
- 量化清单（47-0 场景实测，Decorations 节点共 **1537** 实例）：
  - 科技残骸 `SM_Prop_Scav_Scrap_*`（46/13/43/49/42/40/45/27/41 等 10 种）≈ **294 个**
  - 木箱 `SM_Prop_Crate_*`（01/02/03/04/09/15 六种）≈ **161 个**
  - 异形红植物 `Flower_01/02/03` + `Fern_01/02` ≈ **139 个**
  - 科技地贴 `SM_Env_Ground_Greeble_01–04` ≈ **89 个**
  - 青蓝灌木 `Plant_Shrub_01/02` ≈ **69 个**
  - **以上合计 ≈752 个（占 G3 层 49%）**，与 GLM 视觉层已剔除的类别一致（GLM 层 232 实例全部为暖色 4041/协调 4006 件）。
  - 单一资产重复度：`SM_Env_Rock_08` 一个 448 个（29%）——灰白岩"城墙感"的直接来源。
- 建议：G3 侧 g3_content 池调整——剔/换上列五类（可改用 GLM 层同款 4041 暖色植被与 Small_Rocks），`Rock_08` 降频并混入 Rock_04–07 与 4041 崩壁件打散重复感。

## I11 g4_export Visual 节点缺 type 属性 —— GLM 越界一行修复，请复核收编

- 现象：`g4_export.py` 生成 tscn 的 `[node name="Visual" parent="." index="4"]` 缺 `type="Node3D"`，Godot 实例化时丢弃全部视觉子节点（日志 "has vanished"，423 实例消失）。
- GLM 改动（保护文件越界，一行）：line 401 → `'[node name="Visual" type="Node3D" parent="." index="4"]'`。
- 请 Qwen 复核该行并收编；如有导出器测试请补对应用例。

## I12 rebuild_visual 引擎阶段 profile 丢失 —— GLM 已修（等价 Codex F3），请复核

- 现象：`pipeline.rebuild_visual` 非 default profile 时，`_run_engine` 二次 `build_scene_text` 从未保存的 stage 字段回落 default → 出图与 plan 不一致（plan 是 natural、场景是 default）。
- GLM 改动（pipeline.py 不在冻结保护清单）：`rebuild_visual` 写入 `g4_params["visual_profile"]` 与 `job["visual_profile"]`；`_build_g4` 记录 `visual_profile`；`_run_engine` 取值链 `job → stage → default`。
- 请 Qwen 复核收编（与 Codex 验收报告 F3 同源）。
