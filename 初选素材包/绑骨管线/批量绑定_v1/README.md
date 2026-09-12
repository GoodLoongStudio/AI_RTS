# 批量角色绑定 v1

多角色动画基线，由 `../native_pipeline/build_batch.py` 重建，逐角色输出 GLB + 逐段
GIF/胶片条 + 技术验证。复用 v3 单角色的重定向逻辑：保留原厂骨架与身体权重，将
Soldier.glb（Mixamo）与 UAL 的动作以世界旋转增量映射到目标原始 rest，30fps，
循环剪辑首尾闭合，按地面做贴地修正。GLB 内嵌贴图（场景挂载时使用）。

## 角色清单（20 个，每个 7 段）

| 目录/角色 | 来源 FBX | 武器 | 骨架骨数 |
|---|---|---|---|
| WW1_German | 4019 Characters_WW1.fbx (Character_German_WW1_01) | SM_Wep_German_Rifle_01 | 49 |
| WW1_British | 4019 Characters_WW1.fbx (Character_British_WW1_01) | SM_Wep_British_Rifle_01 | 49 |
| Monster_MechanicalGolem | 4017 Characters_BR.fbx (#09) | SM_Wep_MechanicalGolem_01 | 49 |
| Monster_ElementalGolem | 4017 Characters_BR.fbx (#02) | SM_Wep_ElementalGolem_01 | 49 |
| Monster_FortGolem | 4017 Characters_BR.fbx (#03) | SM_Wep_FortGolem_01 | 49 |
| Scifi_* ×15 | 4006 Characters.fbx 全部 15 个角色 | SM_Wep_Assault_01 | 50 |

七段剪辑：Idle-loop / Run-loop / Fire / Hit / HitHeavy / Crawl-loop / Death。

## 武器层差异

- 步枪（一战/科幻）：双手握持 IK（rifle_hold）。Fire 为端枪后坐；Hit 为快速中弹顿挫；
  HitHeavy 爆炸后抛死亡；Crawl/Death 单手持枪刚体随动。
- 近战（怪物）：棍/锤刚体绑在右手。站姿（Idle/Run/Fire/Hit）棍身略外倾随身；
  Fire 复用 UAL Sword_Attack 挥击；Crawl/Death/HitHeavy 强制棍身水平沿 +Y，避免
  尸体被棍子撑起或插地。武器顶点权重 1.0 绑 Hand_R，全程刚体。

## 武器库（`武器库/`，161 件独立武器 GLB）

从初选素材包 3 个武器包的手持武器全量提炼（`../native_pipeline/build_weapons.py` 自动发现）：
`科幻_4006`(63) / `怪物_4017`(21) / `末日_463`(77)。一战(4019)、西部(4041)按需求移出
（一战角色 GLB 内仍内嵌其步枪）。
每件：单网格、无骨架无蒙皮、内嵌图集贴图、GLB 即插即用。
- 游戏内已用的 4 件（Assault_01、三根魔像棍锤）**原点=握把点**，游戏缩放已烘焙，
  清单含挂载配置（近战给出 Hand_R 挂载矩阵）；两把一战步枪仅内嵌于角色 GLB。
- 其余 157 件**原点=源 FBX 轴心**，朝向尺寸见预览图。
- 已排除：Mod_* 改枪配件、Scope_* 瞄准镜、弹壳/弹药（清单 excluded 字段）。
- 浏览：`武器库总览_4006/4017/463.png` 分包总览；`武器库清单.json` 记录
  尺寸/顶点/源 FBX SHA-256/挂载方式。重建（可断点续跑）：
  `blender --background --python ../native_pipeline/build_weapons.py`（含逐件重导入验证 161/161 PASS）。

## 文件

- `*.glb`：成品（原厂骨架 + 身体 + 武器 + 7 段内嵌动画；export_yup）。
- `*_build.json`：每段时长/采样数/来源/贴地偏移/动作层说明。
- `*_integrity.json`：原始身体顶点数、骨架骨数、逐顶点权重、源 FBX SHA-256。
- `build_report.json`、`validation_summary.json`：汇总。
- `self_check.json`：交付自检记录（GLB 结构 / Blender 验证 / Godot 引擎审核 / 实机导入契约抽查）。
- `动画审核/<角色>_七段索引.png`、`<角色>_<剪辑>.gif/.png`：逐角色审核图。

## 验证边界

`validate_batch.py` 对每个 GLB 重新导入后检查：原始骨数、骨名子集、身体顶点数 ≥ 源、
7 段时长一致、所有剪辑不穿地、武器相对右手刚性、循环首尾闭合、常规剪辑无水平根位移、
Hit 两帧内冲击峰值并复原、HitHeavy 后抛/腾空/倒地定格。已全部 PASS。

与 v3 相同，这是可重建的技术基线，不替代美术目检：手指近景、武器握持细节、怪物体型
比例下的动作观感请以 `动画审核/` 预览为准。`Scifi_Soldier_Male_01` 与 v3 的
Infantry_native_v3.glb 同源同逻辑，可互替；游戏挂载沿用"绕 Y 转 180°"约定。
