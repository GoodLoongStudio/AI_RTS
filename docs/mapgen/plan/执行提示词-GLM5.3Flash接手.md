# 接手提示词（GLM5.3Flash）— RTS_Map_Tool 剩余任务：G2 放行 → G3 → G4

> 历史交接记录：本轮双执行方任务已更新。GLM当前负责视觉完善，最新完整提示词见 [workbench-team/02-GLM5.3Flash.md](workbench-team/02-GLM5.3Flash.md)，Qwen负责完整管线与集成。本文件的旧阶段限制与旧地貌设计不再定义本轮任务。

> 发给 GLM5.3Flash 的完整接手指令。前置执行方（Qoder）已完成 G1/G2 并把审美/拓扑红线踩坑总结在此。
> **验收约定：次日由 Qoder 按文末「验收清单」逐条验收；不合格打回重做。**
> 工程根目录：`G:\AIRTS\RTS_Map_Tool`（Python 工具）；消费端游戏：`G:\AIRTS\AI_RTS`（Godot 4.7 Mono）。

---

## 0. 你的角色与边界

- 你是 `RTS_Map_Tool` 的实施工程师，继续 4 闸门管线（G1→G4）的**剩余部分**。
- 唯一有效方案文档：`docs/plan/4p-seeded-mapgen-plan.md`（下面简称「方案」）。本提示词是它的执行版；冲突时以方案为准并在汇报中指出。
- **每次只做一个闸门**，做完停下按「汇报格式」输出，等验收。不得跳闸门。
- 例行技术决策自己定，不要来回问；但**审美/拓扑红线（§5）不可违反**，违反即返工。

## 1. 必读文件（按顺序，读完再动手）

1. `docs/plan/4p-seeded-mapgen-plan.md` — 方案总纲（重点：§Implementation Strategy、G3/G4 规格、Progress Tracking）。
2. `docs/plan/执行提示词.md` — 通用硬约束 + 各闸门执行细则。
3. `docs/plan/执行提示词-修订1.md` — 产物精简/review 规则。
4. `rtsmap/contract.py` — 全部参数与 `BLOB_PROTOTYPES`（形状原型 kit）。
5. `rtsmap/gates/g2_layout.py` — 当前 G2 实现（理解 kit/蚀刻口/连通性修复的做法，G3 要复用其几何）。
6. `review/G2/` — 当前 G2 的图（contact.png + seed_16/35/61_overview.png），**先看圖理解目标观感**。

## 2. 当前状态快照（截至 2026-09-05）

- **G1**：256m、无中央战场、出生点多样化；approved seeds = **16, 35, 61**。
- **G2**：已完成 v7+v9(kit)+蚀刻口，三 seed 全 PASS（障碍 ~15–16%、墙完整度 1.00、桥宽达标、关键点连通）。
  - 模型：全图开阔默认；相邻两家一道**连续隔墙**（中部**单桥**缺口）；其中 pair_0 隔墙以 **water 地形**呈现为「河+桥」；**台地**按象限放满 3 个；**岩簇**以 4×4 网格分布铺满全图（含四角）。
  - 形状：curated prototype kit（`BLOB_PROTOTYPES` 固定谐波签名）+ 隔墙/河固定弓形蛇行 + 锥化圆盘并集；**隘口/渡口 = 有机 blob 蚀刻**（圆润凹唇，天然感）。
  - `tests/test_g2.py` 12 passed。
- **G2 尚未 `--approve`**。你第一步：自检 G2 图与指标无回归后，执行放行（见 §3 步骤 1）。
- **G3 / G4 未开始**。

## 3. 剩余任务

### 步骤 1 — G2 放行
- 先看 `review/G2/` 三张 overview + contact，确认符合 §5 红线；跑 `python -m pytest tests -q` 确认绿。
- 无回归则执行：`python run.py --approve G2 --seeds 16,35,61 --note "GLM5.3Flash 自检通过放行"`。
- 有回归则先修 G2 再放行（修时遵守 §5）。

### 步骤 2 — G3：资源配额 + 4006 素材实例化
按方案 G3 规格执行，输入为 G2 approved 的 `runs/<seed>/G2/`：
- **资源配额**（无中央战场适配）：每家 2×ResourceA（home 内、路径距 8–13m）+ 扩张 1A+1B（18–28m）；每条相邻边界（flank）1×A（到两邻家路径距差 ≤20%）。**原方案的"中心 2B+1A"因无中央战场改为：在各 flank 或扩张补 B，保证每家 B 数量相等**；此为本轮允许的偏差，须汇报。
- **净空**：资源格非 blocking、距 blocking ≥2m、资源间 ≥3m、不在进攻走廊核心带、不在基地盘 6m 内。
- **素材实例化**：用 `rtsmap/data/assets_catalog.json`（4006 科幻包：FBX 名/包围盒/图集/类别/是否遮挡）。结构类（rock/ruin/wall/debris）→ 对应 FBX 候选；位置吸附格中心、朝向 90° 步进（岩石可随机 + 0.9–1.2 缩放）；用**实例真实 AABB 膨胀 0.9m 重算 blocking** 并复跑 G2 全部检查，失败换小件或删除；装饰件不进基地盘 10m、不压资源 2m、不进核心带；实例预算 ≤1500。
- **产物**（写 `runs/<seed>/G3/` + `review/G3/`）：`mapgrid.npz`、`mapspec.json`、`manifest.json`、`report.json`、`resources.png`、`resources.json`、`resources_table.png`、`objects.json`、`objects.png`（遮挡红/装饰灰）、`recheck_report.json`、`assets_used.json`；review 出 contact + 每 seed overview。
- **验收**：每家资源配额相等；三项路径距比 ≤1.3；G2 复检全过；实例 ≤ 预算；实例包围盒覆盖原簇格 ≥90%；`pytest` 绿。

### 步骤 3 — G4：Godot 场景导出 + AI_RTS 冒烟
按方案 G4 规格，输入 G3 approved：
- 导出继承 `AI_RTS/source/match/Map.tscn` 的场景到 `AI_RTS/source/match/maps/generated/seed_<N>.tscn`（文本生成）：`size=Vector2(256,256)`、Y=0 平面不动、`SpawnPoints/Marker3D×4`、`Resources` 实例、`Decorations` 下 FBX 实例 + `material_override`（图集取自 `texture_map.json`，用 `ApplyAtlas.gd` 在 `_ready()` 统一挂，不在 .tscn 覆写实例内部子节点）。
- **遮挡物**挂 `StaticBody3D + BoxShape3D`（实例 AABB 的 XZ × 高 2m）并进 `terrain_navigation_input` 组；**装饰物不挂碰撞**。
- 只复制 `assets_used.json` 中用到的 FBX 与图集到 `AI_RTS/assets/models/scifi-worlds/`。
- **Godot 可执行文件**：用 `G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`（方案里旧路径 `G:\Godot_...` 已不存在，以本路径为准）。
- **校验**：`tools/godot/ortho_capture.gd` 正交顶视截图（size=256，相机 (128,50,128)、旋转 (−90,0,0)、视口 1920²）与 Python 图差分 <2%；`tools/godot/bake_probe.gd` 用 AI_RTS 同参数烘焙 navmesh 并 `map_get_path` 测 4 出生点两两+到扩张连通；无白模；无脚本报错。
- **冒烟**：`MatchConstants.gd` 的 `MAPS` 加一条登记；4 名 AI 对战 5 分钟，30s/5min 各截一张，收集 ERROR/WARNING。
- **允许改 AI_RTS 的范围（越界即返工）**：仅新增 `source/match/maps/generated/`、`assets/models/scifi-worlds/`、`MatchConstants.gd` 的 `MAPS` 加一行。其余一律不动。
- **AI_RTS 导航硬约束**：agent_radius 0.9 / cell_size 0.3 / agent_max_climb 0.0 / 烘焙 AABB Y≤5.0。

## 4. 硬约束（违反任何一条即返工）

- 路线 A：Y=0 大平面 + 阻碍物；**不做台地高程/坡道/水面对 AI_RTS 的真实 3D 改造**（G4 只放碰撞盒与平面装饰）。
- 唯一权威数据 = `runs/<seed>/<gate>/mapgrid.npz`；PNG 只是派生视图，**任何代码不得回读 PNG**。
- 下游 npz = 上游全部通道原样复制 + 本闸门新增通道（G3 可重算 blocking/passable，但须另存 `blocking_g2`）。
- 闸门机制：下游运行前检查上游 `approved==true`；`--approve` 只能由人/验收方指令执行。
- 确定性：闸门子 Seed = `sha256(seed|gate|algo_version)`；禁内建 `random`/`hash()`/依赖 set·dict 迭代序；同 Seed 同版本重跑字节级一致。
- 工具链：Python 3.12，仅 `numpy` + `Pillow` + 标准库（scipy 可选）；**禁 matplotlib**。
- 坐标/画布：世界 X∈[0,256]、Z∈[0,256]，cell=1m；画布 2048²、地图区 1920² 偏移 (64,64)、PX_PER_M=7.5；图像 x=+X(东)、y=+Z(南)、上=−Z(北)；文字/图例只在边框区（通道宽数字例外 ≤24px）。
- 改算法必须升 `algo_version`。

## 5. 视觉/地形审美红线（前人多轮踩坑总结，**勿回退**）

1. **开阔为主**：障碍占比控制在 ~12–18%（红警2 量级）；绝不允许回到"雕刻式/实体默认"（曾产出 64% 墙体被否）。
2. **连贯不纸屑**：特征必须是连贯块/线（隔墙连续、河连通、岩簇成团），禁止散点 confetti、禁止碎小漂浮块。
3. **无布尔感**：禁止直切槽/矩形缺口/硬直边；隘口与渡口必须是**有机 blob 蚀刻**（圆润凹唇、天然感），沿用 `proto_blob` 蚀刻做法。
4. **分隔结构**：相邻两家一道连续隔墙 + **单桥**缺口；pair_0 用 water 河+桥；不要多水带交叉、不要中心星形汇聚、不要贯图长墙交叉成乱麻。
5. **分布均衡**：岩簇用 4×4 网格铺满全图（含四角）；台地按象限放满 3 个；禁止只聚中环。
6. **形状风格恒定**：用 `BLOB_PROTOTYPES` kit 签名 + 固定弓形/蛇行/锥化；种子只控制选原型/旋转/拉伸/缩放/位置。
7. **连通性**：玩法关键点（4 出生 + 4 扩张）必须连通、开放域单一；扩张锚不得隔脊线（connector 被墙挡会导致口袋被封）。
8. **后处理勿侵蚀墙/河**：`ensure_single_open`/`fill_pockets`/走廊 carve 不得把隔墙/河冲残（桥变宽口）；强制开阔区要排除墙/河。

## 6. 运行与自检命令

```powershell
cd G:\AIRTS\RTS_Map_Tool
python run.py --gate G3 --seeds approved      # 跑 G3
python run.py --gate G4 --seeds approved      # 跑 G4
python -m pytest tests -q                     # 单元/回归
# 看图自检（必须，逐张）：
#   review/G3/contact.png、review/G3/seed_*_overview.png
#   review/G4/ortho_*.png、diff.png、smoke_30s.png、smoke_5min.png
```

## 7. 汇报格式（每闸门结束）

1. 文件清单（相对路径）。
2. 关键图直接贴（review 的 contact + 每 seed overview；G4 加 ortho/diff/smoke）。
3. `summary`/`report` 关键数字（障碍占比、配额、路径比、实例数、差分率、navmesh 连通、冒烟结果）。
4. 与方案/本提示词的**任何偏差**及原因（无则写"无"）。
5. 需要验收方决定的问题（无则写"无"）。
6. 测试结果 + 复跑命令。
7. 更新方案 Progress Tracking（本闸门标 ✓ 待验收）。
8. **自检声明**：逐张看过图、对照 §5 红线无违反。

## 8. 次日 Qoder 验收清单（供参考，你应预先自查）

- [ ] `pytest` 全绿；G2 已 approve（16/35/61）。
- [ ] G3：配额相等、路径比 ≤1.3、G2 复检全过、实例 ≤1500、覆盖 ≥90%；review 图资源/物件清晰、无压基地/压资源/进核心带。
- [ ] G4：tscn 可被 AI_RTS 加载；ortho 差分 <2%；navmesh 4 出生点两两+扩张连通、烘焙 <10s；无白模；无 ERROR；4 AI 5min 冒烟无卡死、均在采矿。
- [ ] 审美红线 §5 逐条无违反（开阔占比、连贯、无布尔感、单桥、分布均衡、风格恒定、连通、墙河未被侵蚀）。
- [ ] 未越界改 AI_RTS（仅允许三处）。
- [ ] 方案 Progress Tracking 已更新；汇报含自检声明。
