# RTS 建筑、单位与镜头比例微调

## 结论与状态

已在开发源码写入一组保守的、按类型区分的比例调整，并完成实际画面检查、真实对局数值测量和独立复核。**工作区候选 R1 保留，完整阶段状态为 `needs-review`，没有宣称全量回归全绿，也没有晋级为全局 champion。** 用户要求整局试玩由本人进行，因此本轮只做受影响的小功能验证，不做长时间自动玩家模拟。

开发根 `G:/AIRTS/AI_RTS`；所有编辑目标的 workspace checker rc=0，Git 根核验一致。没有更新 `G:/AIRTS/打包版`、发布包、地图工具或引擎。没有抢焦点、移动真实鼠标、弹辅助控制台或操作用户游戏/编辑器。

## 尺寸口径

| 类型 | 本轮变化 | 当前碰撞 / 占地 |
|---|---|---|
| 指挥中心 | +10% | 圆柱半径 3.828m，高 4.543m |
| 车厂 | +20% | 盒 7.944 × 3.672 × 6.108m；逻辑半径 3.972m |
| 兵营 | +15% | 盒 4.784 × 4.8185 × 7.1415m；逻辑半径 3.57075m |
| 矿场 | +20% | 盒 4.56 × 3.144 × 4.644m；逻辑半径 2.322m |
| 机场 | +10% | 盒 3.586 × 9.449 × 8.789m；逻辑半径 4.3945m |
| 三种炮塔 | +15% | 底座半径分别 1.38 / 1.265 / 1.035m |
| 11 类移动单位 | -8% | 保持现有物理形状和碰撞/避让比值；全部尺寸同步 ×0.92 |
| 开局相机 | +10% | 正交 size 42.5 → 46.75；高度 60 → 66m；俯角仍 -45° |

这些是当前米制源码的相对调整，不是旧报告里的“坦克 9 米”。实际坦克资源网格包围尺寸现约 X 2.369 × Y 1.609 × Z 3.499m；重坦约 3.550 × 2.305 × 3.577m。蒙皮步兵的资源 AABB 接近零，已明确标为非动画包络，**不将该值当成人体尺寸，也不拿骨关节盒冒充完整网格**。

所有实体 root scale 保持 1。修改现有 Geometry authored transform，不增加全局运行时缩放系数。碰撞资源尺寸、碰撞中心、Movement/MovementObstacle 半径、选中/高亮/目标圈、模型相关血条高度及狙击手世界空间 muzzle_offset 同步。Geometry 下的炮口只继承一次缩放；carve 仍由运行时现有碰撞/半径规则生成，导航余量不改。

两个 balance 的 construction footprint 同步；独立 JSON 结构比对确认 **除各自 8 个 footprint 外无其他改动**。速度、攻击/视野距离、建造范围、价格和生产时间保持原值。血条屏幕宽度、地面抬升余量、空中垂线与无关特效保持原样。血雾固定 world-space 0.5m 未调整，缩小步兵后相对原标定约差 4cm，未做动态受伤效果验收。

大地图开局系数 0.346 → 0.3806；手动 zoom 上限及地图边界限制不变。`Match.tscn` 的旧编辑器默认 size 21.25 / height 30 同步到 46.75 / 66，并保持原始地面焦点 `z-y=25`。

## 改动文件

- `source/match/units/` 的 19 个实体 `.tscn`：CommandCenter、VehicleFactory、Barracks、OreRefinery、AircraftFactory、AntiGroundTurret、AntiAirTurret、MachineGunTurret、Tank、HeavyTank、APC、TransportTruck、Worker、Scout、Helicopter、Drone、Infantry、Rocketeer、Sniper。
- `source/match/IsometricCamera3D.gd`、`source/match/Match.tscn`。
- `config/balance/demo.balance.v1.json`、`config/balance/adjutant-e2e.balance.v1.json` 的 footprint。
- `tests/automated/UnitRadiusCoverageSmokeTest.gd`、`SizeUnificationRegression.gd` 的精确期望值。容差和几何断言不放宽。
- 新增 `_RtsReadabilityProbe.gd/.tscn`、本任务 plan/prompt/report。测试启动器和运行数据仅在 `agent/runs/20261010-rts-readability/`。

共享工作区起始已有约 956 条 Git 状态，Git HEAD diff 包含大量他人改动，不用于声明本轮范围。本轮以精确文件备份和 SHA256 对照；没有 reset、clean、回滚或覆盖他人改动。备份与最终 hash 在证据目录保留。

## 画面证据

已经实际打开修改前 opening/lineup、修改后 opening/lineup。车厂与矿场相对坦克更突出，兵营/炮塔比例略增，机场塔楼没有额外夸张放大；镜头后退后 19 个模型仍完整可见，无新增裁切或重叠。测试靶场标签只是探针，不写进游戏 HUD。独立审查者也实际打开并检查截图。

- 基线：[opening](../../runs/20261010-rts-readability/baseline-ready/opening.png)、[lineup](../../runs/20261010-rts-readability/baseline-ready/lineup.png)。
- 候选：[opening](../../runs/20261010-rts-readability/candidate/opening.png)、[lineup](../../runs/20261010-rts-readability/candidate/lineup.png)。
- 数据：[baseline](../../runs/20261010-rts-readability/baseline-ready/measurements.json)、[candidate](../../runs/20261010-rts-readability/candidate/measurements.json)、[final replay](../../runs/20261010-rts-readability/final-replay-headless/measurements.json)。

GPU 在独立 Windows desktop 上运行，没有 SwitchDesktop，也没有 OS 输入。截图从引擎 viewport texture 获取，不是截图用户桌面。没有启动或结束用户实例。

## 验证结果

命令均在开发根执行。Godot 路径固定为 `G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe`，每次显式 `--path G:/AIRTS/AI_RTS`，动态 MCP 端口、DCS 端口 0，隐藏控制台，日志记录 argv、PID、时间及 cleanup。

| 检查 | 结果 |
|---|---|
| `dotnet build OpenRTS.sln --no-restore --nologo` | rc=0；0 错误、0 警告 |
| baseline-ready 真实 Match + GPU | rc=0，marker 存在，日志无错误；两次对局可清理 |
| candidate-headless / candidate GPU | 各 rc=0，marker 存在，日志无错误；19 roots、真实位移、退局重开通过 |
| candidate-coverage-headless | rc=0；在真实已初始化 Match 的 19 类实体上执行原 coverage 断言，0 失败 |
| final-headless / final-replay-headless | 引擎 rc=0，全部逻辑断言 0 失败；**有 Minimap dummy texture 读回错误，不能称日志干净** |
| shape-pipeline | rc=0，marker 存在，无 forbidden 输出 |
| structure-placement | rc=0，marker 存在，无 forbidden 输出 |
| battlefield-event-camera | rc=0，marker 存在，无 forbidden 输出 |
| size-unification-regression 初跑 | rc=1，仅 5 个旧尺寸期望失败；相邻/重叠/超范围/驱逐行为断言均过 |
| gpu-size-unification-regression 更新期望后 | rc=0，0 失败，日志无错误 |
| production-queue / spawn-point-regression / muzzle-discipline | 无头与 GPU 都 rc=0、各功能断言 0 失败；**退出有 RID/ObjectDB/resource 泄漏，严格 gate 不绿** |
| unit-radius-coverage 原孤立夹具 | rc=0、0 几何失败，但缺 Match 父节点引起 SCRIPT ERROR；替代真实-Match coverage 已单独通过，未修改夹具以掩盖错误 |
| balance-config-runtime | rc=1，4 个旧平衡期望失败；用修改前精确 balance 配置重跑仍同样 4 个失败，证明不是本次 footprint 改动 |
| unit-grounding | rc=0，但夹具引用不存在的 generated/16-0 地图并有 SCRIPT ERROR；不算通过 |
| 追加 final-gpu | rc=1；记录文件显示 1 失败且 opening PNG 缺失，stdout 后段缺失，原因未确认；不用该轮替代前面成功的截图证据 |
| 追加 final-gpu-verified | 异常 rc=3221225478；Windows 事件确认 coreclr.dll / 0xc0000006；未完成该轮，根因未定 |

准确入口：

```powershell
python agent/runs/20261010-rts-readability/verify.py --probe candidate-headless
python agent/runs/20261010-rts-readability/verify.py --probe candidate
python agent/runs/20261010-rts-readability/verify.py --ids unit-radius-coverage,shape-pipeline,balance-config-runtime,structure-placement,production-queue,spawn-point-regression,battlefield-event-camera,muzzle-discipline,unit-grounding,size-unification-regression
python agent/runs/20261010-rts-readability/verify.py --gpu-tests --prefix gpu- --ids production-queue,spawn-point-regression,muzzle-discipline,size-unification-regression
python agent/runs/20261010-rts-readability/verify.py --baseline-config --prefix baseline- --ids balance-config-runtime
```

以上是本轮实际执行命令。证据目录不覆盖，重跑需使用新的 `--probe` 名或 `--prefix`，不能直接重用历史名称。最后增强运行器，将普通 `ERROR:` 也纳入失败，避免只查 suite forbidden patterns 漏掉 Minimap 错误；旧 launch.json 中的 passed 按当时过滤器解释，不能代表完整无错误。

最终真实对局复验：坦克实际移动约 5.099m，到目标余距 0.558m；正常生产队列真实部署坦克，距放大的车厂 8.693m，大于逻辑下限 5.912m，生产单位 root scale=1；两次 Match 均释放并重新开局。全部测试拥有的引擎进程已退出，详见 cleanup.json。

## 独立复核与剩余边界

`/root/readability_review` 使用自己的精确备份比对和截图检查，结论：无本轮阻断性漏同步，数值倍率、两份配表、炮口继承与镜头焦点一致；血雾 world-space 常量是非阻断性提醒。该复核是只读审查，没有独立动态战斗测试。

未跑整局手动玩法、全量无关回归、大图全缩放边界、动态采矿/受伤特效及大部队性能。不把截图当成这些行为的证明。已有测试泄漏未完整做修改前后 A/B，不能仅凭 rc=0 宣称无泄漏；本轮不扩展成修复整个测试框架的任务。

候选不再追加游戏逻辑补丁；全局 champion 仍是记录的基线，连续未提升轮数 1。当前比例候选保留在源码供用户新开局观察，但 S3 由于既有夹具错误、未全量回归和追加 GPU 异常仍为 `needs-review`。当前已运行对局不会自动替换实体尺寸，观察新值需要用户自己重开一局。

## R2：主基地、矿场与 Scout 退役（用户追加要求）

用户要求矿场更大、主基地是最大的建筑；随后明确选择“停用 Scout 兵种，只保留 Drone”。红框中的细长旧模型确为 `Scout` 的悬浮摩托，正式 `Drone` 早已引用 `SM_Prop_Drone_03.fbx`。此前 Scout 仍是机场合法产品，不仅是截图多摆了旧模型；本轮因此撤下兵种，而非仅隐藏外观。

本轮只在主工程 `G:/AIRTS/AI_RTS` 修改，不更新打包版、不操作用户编辑器/游戏实例。实际编辑目标通过 workspace checker rc=0。动笔前目标 SHA 与 R2 精确备份相同；其他人的未提交改动保留。

### 数值与写入范围

两栋建筑相对 R1 再线性放大 30%；没有增加全局缩放或缩放逻辑根。实时模型包围尺寸按 X/高 Y/Z 记录，均为网格资源 AABB，不冒充真实实体体积。

| 项目 | R1 | R2 真实 Match |
|---|---|---|
| 主基地模型包围尺寸 | 7.653 × 4.545 × 7.653m | 9.949 × 5.908 × 9.949m |
| 主基地逻辑/施工半径 | 3.828m | 4.9764m |
| 主基地圆柱碰撞 | 半径 3.828 / 高 4.543m | 半径 4.9764 / 高 5.9059m |
| 主基地碰撞中心 Y / 选择圈 | 2.2715 / 4.2108m | 2.95295 / 5.47404m |
| 矿场模型包围尺寸 | 4.559 × 3.144 × 4.649m | 5.927 × 4.087 × 6.044m |
| 矿场逻辑/施工半径 | 2.322m | 3.0186m |
| 矿场方盒碰撞尺寸 | 4.56 × 3.144 × 4.644m | 5.928 × 4.0872 × 6.0372m |
| 矿场碰撞中心 Y / 选择圈 | 1.572 / 2.64m | 2.0436 / 3.432m |
| 现役实体种类 | 19（含 Scout） | 18（不含 Scout） |

主基地的 X/Z 两边均超过其他建筑，地面包围面积约 98.97m²、包围体积约 584.75m³，均最大。机场尖塔仍更高，约 9.45m；没有为了压过一根天线把基地继续无界放大。矿场与兵营的地面体量更接近。镜头保留 size=46.75、height=66；其他建筑、机动单位、速度、武器/视野、服务范围、费用与时长都未改。

改动文件组：
- `source/match/units/CommandCenter.tscn`、`OreRefinery.tscn`：视觉、形状尺寸/中心、障碍半径、三种圈与血条锚点同步。根 scale=1，carve 保留原形状来源/裕量，由运行时重新生成顶点。
- 两份 `config/balance/*.balance.v1.json`：仅上述两个施工 footprint 及删除 Scout 的单位/生产定义。
- 两份 `config/godot/*.assets.v1.json`、`BalanceCatalogContracts.cs`：删除 Scout 映射与强制必备项，避免旧必备契约把新配置判成残缺。
- `SelectionPortraitPanel.gd`：撤下 Scout 头像映射；机场产品来自现役目录，不再能生产 Scout。
- 副官的 `behavior_tree.py`、`rules_fallback.py`、`squads.py`：现役侦察/空军默认类型不再含 Scout，但 scout 指令、任务角色、调度 lane、增益 tag 全部保留，Drone 仍可侦察。
- `e2e_dual_layer.py`、`test_e2e_fixture.py`、半径/尺寸断言表及当前 readability/size/reach/icon roster：同步退役并新增正反验证，未放宽容差。

原 `Scout.tscn` 和模型资产未删除，SHA 不变，仅作为非现役历史资源保留。其他旧诊断/迁移探针可能还显式加载 Scout，不能用其旧名单代表现役目录；不得自动把它加回生产表。新对局只认当前目录/清单。图标生成器没有执行，未覆盖旧公共图标。

### 本轮闭环证据

证据根：`agent/runs/20261010-rts-readability/`。最新正式引用的候选为 `r2-retirement-gpu-retry`，不是第一次失败的 `r2-retirement-gpu`。

| 验证 | 退出码 / 结论 |
|---|---|
| `dotnet build OpenRTS.sln --no-restore --nologo`（两次） | rc=0，0 警告、0 错误 |
| R2 前基线 / 建筑补丁 / 退役补丁的新鲜无头真实 Match | 引擎 rc=0、功能断言 0 失败；均有 Minimap dummy texture 的 `Parameter t is null`，严格运行器 rc=1，不算干净通过 |
| `r2-buildings-gpu` | rc=0、无 forbidden/engine errors；模型、移动、生产、退局重开通过 |
| `r2-retirement-gpu`（第一次） | rc=4294967295、无完成标记；日志停在 Drone 已入队，不能证明实际出厂。失败证据保留，原因未归因 |
| `r2-retirement-gpu-retry` | rc=0、50 条断言全通过、无 forbidden/engine errors、cleanup=true |
| `shape-pipeline` | rc=0、0 失败、日志干净 |
| `size-unification-regression`、`spawn-point-regression` | 引擎 rc=0、功能断言 0 失败；分别有夹具 current_scene 条件错误、退出资源/RID/ObjectDB 泄漏等，严格运行器 rc=1 |
| `runtime-placement`、`same-frame-overlap-placement` | 引擎 rc=0、功能断言 0 失败；无头纹理错误/退出泄漏仍红 |
| `reach-geometry` | 引擎 rc=0、0 失败标记，但夹具把实体挂在非 Match 下，产生 null Match SCRIPT ERROR，不能算干净通过 |
| Python 配置、编组、移动、探索、规则回退 | 150 tests，rc=0；独立复核另跑配置 5 tests，rc=0 |
| Python behavior-tree + fixture + rules 共 73 tests | rc=1，仅既有响应半径断言失败：20 < 武器最大射程 40。精确备份和候选都为同一 20/40，未修改这些值 |
| C# Core 全集 | rc=1，生产 3 + 配置 22 失败；换本轮前的精确原始 catalog 后仍为完全相同 25 条失败。对照日志保留，没有据此扩大本轮玩法修改 |
| `LocalMatchStartupIntegrityTest` GPU | 当前及原 catalog+manifest 控制组均 rc=1，仅“1 名玩家”失败；测试仅等 30 process frames，Match 实际要等导航初始化后建玩家。真实 readiness 探针已确认玩家、单位、生产、退局重开正常。未改短等待夹具的断言使它变绿 |

最初 Python 命令因未配置 `PYTHONPATH` 且选了不存在的 `test_squads` 导致导入错误；已按真实模块名 `test_squad_composition` 和 `PYTHONPATH=G:/AIRTS/AI_RTS/source` 重新执行。一次 local-startup 运行器收尾读日志报 FileNotFound、随后一条命令创建进程报目录无效；后续路径身份核对存在且一致，未迁移工程、未删除文件。此环境异常未归因，不当作功能成功。

最新 GPU 真实 Match 核验：Scout 无 unitType 映射且机场拒绝生产，Drone 映射仍为 drone、正常排队且真实部署；坦克实际移动约 5.099m、目标余距 0.558m；生产坦克距车厂 8.693m > 下限 5.912m；两次 Match 均释放。矿场赠车回归 C3 走实际完工链，赠车距建筑约 11.03m > 下限 4.37m；该套件的退出泄漏仍单独记录，不被成功功能断言抵消。

主线与独立 reviewer 均实际打开最新 `opening.png` 和 `lineup.png`：主基地体量明显最大、矿场增大、旧 Scout 不在现役陈列、Drone 模型正常；未见新增截断或重叠。reviewer 自己做结构/数值对比，确认 18 种实体没有缺失/未知资产映射或破损生产引用；无本轮阻断性漏同步。其发现的 E2E 顶部旧 Scout 文案已同步改正。

### 可重放命令与决策

```powershell
$env:PYTHONPATH='G:/AIRTS/AI_RTS/source'
dotnet build OpenRTS.sln --no-restore --nologo
python agent/runs/20261010-rts-readability/verify.py --probe <fresh-label-ending-headless>
python agent/runs/20261010-rts-readability/verify.py --probe <fresh-label-without-headless>
python agent/runs/20261010-rts-readability/verify.py --ids size-unification-regression,spawn-point-regression,shape-pipeline --prefix <fresh-prefix>
python agent/runs/20261010-rts-readability/verify.py --ids runtime-placement,same-frame-overlap-placement,reach-geometry --prefix <fresh-prefix>
python -m unittest adjutant_coordinator.tests.test_e2e_fixture adjutant_coordinator.tests.test_squad_composition adjutant_coordinator.tests.test_safe_movement adjutant_coordinator.tests.test_explore_frontier adjutant_coordinator.tests.test_rules_fallback
dotnet run --project tests/core/AI_RTS.Core.Tests.csproj --no-restore
```

所有 Godot 实例明确 `--path G:/AIRTS/AI_RTS`，动态分配 MCP 端口，DCS=0，隐藏辅助控制台；GPU 在不切换的独立 Windows desktop 中截图，不影响用户前台/鼠标。JSON launch 记录 PID/argv/开始时间/退出和清理；证据不覆盖，失败与重跑并存。静态视觉任务没有做完整玩家 UI 录像，不能宣称玩家输入链路或完整对局已验收。

R2 的目标比例、退役内容和受影响真实生产链已经独立核验；源代码保留候选供用户新开局观察。由于旧夹具错误/泄漏、一次未解释 GPU 退出、全量无关回归未执行，全局状态继续 `needs-review`，不把功能局部通过冒充全局 champion 晋级。R2 未提升全局 champion，任务累计未提升轮数为 2（R1/R2）；不继续堆补丁或擅自扩大修复范围。用户自己进行整局主观试玩；当前已存在的对局/旧客户端不热替换资源，需新开局，联机各端应使用同一内容版本。

最终清理：`r2-cleanup.json` 核验 14 个有 launch 记录的本轮实例 PID 全部已退出，当前 readiness/local-startup/spawn 探针进程为 0；用户实例未操作。`r2-final-hashes.json` 保存 20 个目标文件的最终 SHA/mtime。定向 `git diff --check` rc=0，仅 Python 文件的 CRLF/LF 策略提示，没有空白错误；未批量转换换行。
