# GLM_TO_QWEN — GLM5.3 Flash 第一轮交接报告（2026-09-06）

> **对齐声明（≤10 行）**：目标=在冻结视觉接口上完成 G4 自然感与素材完善，产出固定地图/固定镜头前后对比并交回集成复验。输入=`00/01/02/03` 提示词、Qwen 交接包、`初选素材包`、工作台最新产物。输出=`handoff/` 下本报告 + `ISSUES.md` + `asset-candidates.json` + `visual-change-manifest.json` + `visual-review/`。允许修改范围=仅 `handoff/` 交付与 `tmp_logs/` 隔离测量工程；**本轮未修改 rtsmap/tests/游戏侧任何文件**。本轮完成条件=交接核对（结论：未就绪）+ 可并行推进的素材研究全部落地；视觉实施因 I1–I4 阻塞，未开始。

## 状态：NOT_READY_FOR_VISUAL（阻塞在工程前置，非视觉方原因）

`02-GLM5.3Flash.md` 要求「交接状态必须为 READY_FOR_VISUAL 且所列命令、文件和基准图真实可用」。核对结论：**交接包不存在，视觉接口不存在，G4 真实几何不存在，G2 未全绿**。按 02 文档既定分支处理：写问题单（见 `ISSUES.md` I1–I5）+ 推进只读素材研究。未重写导出器/height/G2/导航，未触碰受保护文件。

## 一、V0 接手复现：无法执行（如実记录）

无可复现的基准样例与命令清单。仅核对了 Qwen 今日（2026-09-06 15:41–16:49）工作台任务的只读产物：

- 最新任务 `workbench_output/cfb60de75bbe4ba8825c70c422c2f3e7/`：布局 36 / 地貌 0，algo 7.4.0，`preview_only=true`，105.2s，`all_pass=false`（选中 attempt 3 仍有 `open_single_pass`、`plateau_strategy_pass` 失败；16 attempts 全部含失败项）。
- `review/G2/seed_36_overview.png` 已查看：中央河+3 桥、两大湖、4 台地（P0/P1 本阵台地+中央争夺台地）。**该形态即后续视觉工作的结构依据**，与 03 文档"保持当前 G2 方向"一致。

## 二、本轮实际完成（可复用产物）

1. **`asset-candidates.json`**：A/4006 共 34 项（ready 18 + 需调色 3 + 异形点缀 6 + 视觉核验剔除 5 + 首轮不用 2）+ B/4041 暖色备选 28 项 + 10 条禁用清单。每项含源完整路径、Godot res 映射、图集、size_xyz、min_y、原点说明、预览路径、用途、贴附面、允许缩放/yaw、碰撞标志、**UV/材质审计**、**肉眼核验结论**、**游戏资产树就位状态**。4006 尺寸取自现有 `assets_catalog.json`；4041 尺寸为 Godot 4.7.1 headless 真实导入实测（脚本 `tmp_logs/glm_measure_4041/measure.gd`，30/30 成功）。
2. **UV/材质审计（64/64 项）**：全部有 UV，零白模风险。材质归属干净：4006 岩崖=`ScifiMat`、地表=`Base_Lambert1`、植被=`Base_Lambert3`；4041 全部=`Frontier`。单件三角面 42–2050，dressing 性能余量大。
3. **肉眼核验修正（重要）**：4006 的 `Grass/Fern/Flower` 系列**实为红色异形植物**（名不副实，只能做风格点缀）；`Ground_Greeble/Junk` 系列**实为科技残骸**（六边底座青光纹/警戒条纹/电路纹，已从自然池剔除）。4006 真正干净的自然物=崖件+岩石+`SM_Generic_Small_Rocks`。自然植被的主选因此落到 **B 轨 4041**（旱植/灌木/芦苇，Demo 场景+地形总表已确认暖砂色调、图集生效）。
4. **游戏侧就位情况（实测）**：A 轨 25/34 已在 `assets/models/scifi-worlds/4006_科幻世界/`（含 .import），需资产接口补拷贝 7 件（Small_Rocks_01/02、Blob_01/03、Grass_01/04、Ground_Blob_01）。
5. **关键集成事实（给视觉接口设计）**：
   - 两包原生尺度差约 2–3×，禁止统一 scale 跨包套用；各包单图集（4006=`PolygonScifiWorlds_Texture_01_A`，4041=`PolygonWesternFrontier_Texture_01_A`），禁止跨包贴图。
   - 4006 崖件 min_y=-3.3~-25.9（原点在模型上部）：接口必须支持 `y_offset = -min_y×scale` 贴地规则。4041 崖壁 min_y≈-0.2~-0.7 近底原点。
   - 3m 台地高差参考缩放：4006 崖件 0.12–0.18、4041 崖壁 0.6–1.2；已在候选池逐项给允许区间。
   - `Ground_Junk_04` 双材质（SCAV+SHD）且 `mat_texture_overrides.json` 无对应条目——已剔除，无遗留风险。

## 三、对视觉方向的建议（待接口冻结后实施，已按核验修正）

- **结构性自然物走 A 轨**（4006 崖+岩+碎石，与现有游戏资产同包零风险）：崖件沿崖线主次分组（主崖面覆盖长边 + 辅助崖块转角 + 大岩锚点 + Small_Rocks 碎石带）。
- **植被与暖意两条路**：①默认=A 轨结构物 + 地面材质暖土色（profile 调色），植被用 4006 异形红系做受控点缀（科幻风格延续）；②若要自然荒漠/草原植被=B 轨 4041 植被（含芦苇水岸专用），需风格拍板 + 引擎内逐件核验后整轨启用。不混拼单件（02 文档跨包禁令）。
- `Blob`/`Ground_Blob` 系作低频地斑**必须**有接口调色支持（原始深蓝灰不可直接用）。
- 布局规则草案：坡道口净空 3m 语义不动；装饰按地貌成簇（崖脚/水岸/台地顶缘），密度梯度，禁区=出生盘/资源/桥头/坡口/主通路。

## 四、待 Qwen 回应（对应 ISSUES.md）

1. I1 补齐六件套交接包（含 3 张基线图、实际命令、file-state 哈希）。
2. I2 实现并冻结 `rtsmap/presentation/` 视觉接口（01 文档第五节 10 条），至少 1 个样式在 3 张基线图跑通。
3. I3 G4 真实几何（台地/坡面/桥/水域）落地后，GLM 拍「后」图与旧 `user-g4-before.png` 对照。
4. I4 G2 修到全绿并冻结三张基准图，V1 才能在固定图上迭代。

## 五、诚实记录

- 本轮未产出任何前后对比图（无可拍之「后」）；`visual-review/` 目录内仅放说明文件。
- 参考视频未播放：`reference_alignment=not_verified`。
- `requirements-checklist.json` 不存在（Qwen 义务），GLM 未代填、未伪造。
- 本轮 GLM 修改文件清单：仅新增 `handoff/` 下 5 个文件与 `tmp_logs/glm_measure_4041/`（隔离测量工程）。哈希见 `visual-change-manifest.json`。
