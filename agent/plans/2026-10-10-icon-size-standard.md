# 计划：生产卡片图标尺寸规范（建筑/单位观感大小统一）

- 建立：2026-10-10
- 用户口径（原话）：「现在这些UI的建筑的大小你也规范一下，基地这么小，兵营这么大，都不协调」
- 闭环报告：`agent/reports/closed-loop/2026-10-10-icon-size-standard.md`

## 1. 问题量化（改动前，headless 实测可见内容占比）

| 图标 | 占满度 | 图标 | 占满度 |
|---|---|---|---|
| 兵营 barracks | **1.000**（顶满四边） | 基地 command_center | **0.563** |
| 矿场 ore_refinery | **1.000** | 车厂 vehicle_factory | 0.500 |
| 对空炮 anti_air_turret | 0.844 | 对地炮 anti_ground_turret | **0.352** |
| 机枪塔 / 机场 | 0.766 / 0.742 | **全部 19 张极差** | **0.648** |

## 2. 根因

图标由 `tests/automated/NewUnitsLineupSmokeTest.gd` 用 SubViewport + 正交相机渲染生成，
但相机 `size` 与取景高度是**逐条手调**的（`["soldier", InfantryScene, 0.9]` … `["command_center", CommandCenterScene, 16.0, 3.0]`），
注释自己写着"步兵小、建筑大，否则会被裁切" ⇒ 观感大小必然不一致。
侧栏用 `TextureRect + STRETCH_KEEP_ASPECT_CENTERED` 显示，所以**图内占满度直接决定观感大小**。

## 3. 方案：把"手调"换成"一条自动取景规则"

在同一个生成器里改为 `_render_normalized_icon()`：

1. 按模型**实际包围盒**（子树所有 MeshInstance3D 的世界 AABB）定取景中心与初值；
2. **渲染→量可见内容（非透明像素包围盒）→改相机 size/中心** 迭代收敛到
   `ICON_TARGET_FILL = 0.82`，并迭代居中（≤2px）；
3. 收敛策略：线性步进夹在 `[0.4, 2.5]`，溢出按 2 倍缩回、空图按 0.5 放大（永不塌到 0）；
4. 收尾回退到"最接近目标"的那一次取景；
5. roster 补上此前漏掉的 **worker（矿车）**（它在 TABS 里，却不在生成清单里）。

同时新增 headless 回归测试 `IconSizeStandardSmokeTest`：
断言 TABS 里**每个** icon key 都有 PNG、占满度 ∈ [0.72, 0.92]、居中偏移 ≤8px、
**全部图标极差 ≤ 0.12**（"协调"的可量化判据）。

## 4. 验证

1. 重新渲染 18 张图标 → 逐条打印 fill/居中/相机 size；
2. `IconSizeStandardSmokeTest`（rc=0）；
3. 拼图 before/after 对照 + **在真实侧边栏里截图**（建筑页/载具页）并亲自查看；
4. 记录"改完必须重新导入资源（`--import`），否则运行时仍用旧 `.godot/imported` 缓存"这条坑。

## 5. 范围与风险

- 只改**图标资产与生成器**，不动侧栏布局/格子尺寸/造价/解锁逻辑；
- 单位图标也一并规范化（同一套规则；用户只点名建筑，但"规范"应是一条规则、一套资产）；
- `scout.png`（2026-10-10 已退役、TABS 0 引用）保持原样，只记录不删。
