# G4 视觉扩展接口（visual-api）— Qwen → GLM 冻结契约

版本：`visual_api_version = 1.0.0`（`rtsmap.presentation.VISUAL_API_VERSION`）。
实现位置：`rtsmap/presentation/visual.py`（入口）、`rtsmap/presentation/__init__.py`（导出）、
样式配置：`rtsmap/data/visual_profiles/<name>.json`（当前仅 `default.json`）。
场景消费位置：`rtsmap/gates/g4_export.py::build_scene_text`（把 VisualPlan 写成 .tscn 的
`Visual` 节点 + 材质参数）。

## 1. 入口签名

```python
from rtsmap.presentation import build_visual_plan, load_profile, build_zones, plan_fingerprint

profile = load_profile("default")            # 读 rtsmap/data/visual_profiles/default.json
plan = build_visual_plan(context, profile, visual_seed)   # -> dict (VisualPlan)
```

- `context`：只读输入（见 §2），由 `g4_export.build_scene_text` 构造；GLM 不得修改权威通道。
- `profile`：样式配置 dict（§4）。
- `visual_seed`：int，独立视觉随机流；**不影响** G1–G3 逻辑、地貌 Seed、碰撞、导航。
- 返回 `VisualPlan`（§3）。缺资源/不兼容抛 `rtsmap.presentation.VisualPlanError`（**不静默回退**）。

## 2. context（只读输入）

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `map_id`, `world_size_m`, `cell_m` | str / [f,f] / f | 任务 ID、世界尺寸（米）、逻辑格（1m） |
| `height` | ndarray (H,W) f4 | G2 权威逻辑高度（0.6/2.1/3.6/-2.4 分类值） |
| `heightfield` | ndarray (H+1,W+1) f32 | G4 显示高度场（顶点=世界整数坐标；平顶/连续坡/岸坡/桥面） |
| `water_footprint` | ndarray bool | 水体足迹（含桥下） |
| `blocking`, `blocking_g2` | ndarray u1 | G3 重算阻挡 / G2 原阻挡 |
| `terrain`, `passable`, `lane_core` | ndarray | G2/G3 通道 |
| `plateaus`, `bridges`, `rivers`, `lakes` | list[dict] | 台地/桥/河/湖几何（outline、ramp_centers/ramp_dirs、a/b） |
| `starts`, `resources`, `expansion_anchors` | list | 出生/资源/扩张锚（保护区来源） |
| `lanes` | dict | 路线折线（主/侧/经济） |
| `ramp_blend`, `apron`, `shore`, `bridge_mask`, `water_mask` | ndarray bool | 坡面带/崖脚/岸坡/桥/水（过渡带） |
| `catalog`, `catalog_list` | dict / list | 资产目录（res_path → {size,min_y,atlas,category,blocking,terrain_types}） |
| `g4_params` | dict | G4 参数（含 visual_profile 名） |

## 3. VisualPlan（输出，机器可校验）

```jsonc
{
  "api_version": "1.0.0",
  "style_version": "1.0.0",            // 样式版本（GLM 改样式必须 bump）
  "profile": "default",
  "profile_sha256": "<hex>",           // 样式文件哈希（复现用）
  "visual_seed": 12345,
  "materials": {                        // 材质/调色（g4_export 写入 .tscn）
    "terrain_albedo_color": "0.80, 0.72, 0.60, 1",
    "terrain_uv_scale": 0.16,
    "water_albedo_color": "0.22, 0.42, 0.55, 0.88",
    "water_roughness": 0.25,
    "bridge_albedo_color": "0.55, 0.47, 0.38, 1"
  },
  "tint": { "cliff": "1.26,1.10,0.88", "shore": "...", "scatter": "" },
  "instances": [ {                      // 合法视觉实例（装饰，无碰撞）
      "category": "cliff|shore|scatter",
      "asset": "res://assets/.../SM_Env_Rock_01.fbx",   // 源路径（唯一身份）
      "atlas": "res://assets/.../Texture_01_A.png",
      "name": "SM_Env_Rock_01.fbx",
      "x": 12.5, "z": 34.5,            // 世界坐标
      "yaw": 37.0, "scale": 1.05,      // 姿态/缩放
      "footprint_m": [3.1, 2.8],       // 有向包围（校验用，不只中心点）
      "origin_min_y": -6.6,            // 模型原点（贴地 y = 地表 - min_y）
      "ground": "surface",             // 贴地方式
      "collision": false, "blocking": false,
      "tint": "1.26,1.10,0.88"
  } ],
  "asset_dependencies": [ {"asset": "res://...", "atlas": "res://..."} ],
  "stats": { "total": 522, "cliff": 170, "shore": 68, "scatter": 284, "budget_total": 700 },
  "warnings": [],
  "checks": {                           // 内置校验（全 true 才返回）
    "footprint_protection_pass": true,  // 实例有向包围不侵入保护区（非阻挡格）
    "bounds_pass": true,
    "collision_free_pass": true,        // 装饰不带碰撞/不改可走性
    "budget_pass": true,
    "assets_resolvable_pass": true,     // 资产在 catalog 且源文件存在
    "no_logic_channels_touched": true
  }
}
```

`plan_fingerprint(plan)` → sha256：同 (context, profile, visual_seed) 必须同指纹（确定性）。

## 4. 样式配置（default.json）

`materials`（上表）、`cliff_rocks{enabled,spacing_m,scale_range,large_chance,max_footprint_m,budget}`、
`shore_props{enabled,spacing_m,scale_range,plant_chance,budget}`、
`scatter{enabled,attempts,budget,max_size_m}`、`budget_total`、`tint`。
GLM 可新增 `<name>.json` 复制修改；`build_visual_plan(context, load_profile(name), seed)` 即用新样式。

## 5. 保护区（build_zones）

`build_zones(context)` → `{forbidden, decorable, blocking, res_clear}`：
- `forbidden` = 水(非桥) ∪ 桥 ∪ 桥外扩 ∪ 坡面带 ∪ 坡带外扩 ∪ lane_core ∪ 出生22m ∪ 扩张16m ∪ 资源6m。
- 实例有向包围格若落在 `forbidden` 且非 `blocking` → 校验失败（拒绝该实例）。
- GLM 只能**收紧**（再加禁止区），不能放松。

## 6. 固定逻辑、只重建视觉（交接要求 #7）

```powershell
# 逻辑数据不变，仅换视觉 Seed 重生成场景+截图（前一版归档不覆盖）：
python -m pytest tests/test_visual_api.py -q          # 契约测试（含视觉隔离断言）
```
工作台 HTTP：`POST /api/jobs/<id>/rebuild_visual {"visual_seed": N, "profile": "default"}`
→ 归档 `g4/visual_v<k>/` + 旧截图，`visual_version++`，重跑 G4 场景+引擎截图；
G1–G3 权威 npz 哈希不变（pipeline 断言）。

## 7. 截图（交接要求 #8）

`tools/godot/ortho_capture.gd`：`--map=<res> --out=<png> --size=256 [--oblique] [--flat]`。
正交全图 / 游戏斜视 / flat(差分) 三种，无需改核心截图器。局部检查点：用 `--oblique` 配合
相机参数扩展（GLM 可在不改核心的前提下另写局部镜头脚本）。

## 8. 契约测试（交接要求 #9）

`tests/test_visual_api.py`：schema/确定性/保护体积/无碰撞/缺资源报错/视觉隔离/预算。
GLM 改样式后必须全绿：`python -m pytest tests/test_visual_api.py -q`。

## 9. 当前基线视觉状态（Qwen 交付）

- 地形可视面：与碰撞同源的“高度板盒顶”（暖土色 unshaded）。**已知限制**：开放单面
  高度场 trimesh 在本工程 GL 兼容渲染下黑面（bake_test/ortho 实测），故基线用盒顶；
  trimesh 仍用于点击/射线/碰撞源。GLM 应把可视面升级为 trimesh+贴图+光照（含崖脚/岸边过渡）。
- 崖脚/岸边/坡面：已有连续几何（apron/shore/ramp_blend）+ 默认岩件/岸件/点缀实例。
- 资产：仅用 `rtsmap/data/assets_catalog.json` 内 4006 包；未导入贴图时实例呈白色（导入后正常）。
