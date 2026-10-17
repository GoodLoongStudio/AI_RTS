# 炮弹与子弹发射位置修正：闭环记录

任务始于 2026-10-10，复验日期 2026-10-11。状态：**needs-review**。主要武器出射位置已有几何、真实攻击命令和连续录像证据；全量首轮及部分串行复核已有红项，严格日志门禁也未通过，不晋级全项目 champion。产品编辑和后台测试已结束，剩余复核范围如实保留。

用户最终选择：**保留装甲运兵车现有模型，这轮只修其他武器**。该车没有可识别枪管，本轮不补武器模型、不声称其枪口已标定。

## 工程身份与范围

开发根和 Git 根均为 `G:/AIRTS/AI_RTS`。根目标、实际源码目标及本报告/计划/提示词的 `check_workspace_target.py --mode develop` 检查 rc=0。验证入口明确 `--path G:/AIRTS/AI_RTS`。打包版没有更新。

共享树在收尾时有 1038 条未提交状态记录，包含大量原有工作；没有 reset、clean、提交、批量搬移或覆盖其他人的工作。本轮产品子集 SHA256：`942f996f0f579944b3e97a6be98e460a8719d4d61835a033a2e974e56674cd3a`，仅代表列明的产品文件，不是全仓库 tree hash。独立 reviewer 的 13 个产品文件与当前文件逐个 hash 相同。

最终几何数据冻结在 [final/geometry-provenance.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/final/geometry-provenance.json)，保留原始来源、mtime 和 SHA256；当前源文件与探针 hash 在 [source-hashes.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/final/source-hashes.json)。不以早期截图或被后续探针覆盖的 positions.json 作为最终依据。

## 根因与实现

主因是换成当前 Synty 模型后，旧 `ProjectileOrigin/MuzzleL/MuzzleR` 坐标没有按实际炮管重标定。“弹体等于 Marker”能通过，但 Marker 本身仍在炮管之外。最终通过真实 Match 的导入 surface 顶点、端面三角形连通组件和 GPU 正面图识别单个实际出口。重坦、直升机、防空架的多个出口不能平均成一个虚构枪口。

另有共享坐标问题：Rocket 的 Curve3D 使用局部坐标，旧代码写世界坐标；客户端回放在炮弹自身高度补偿前重复抬高落点；hitscan 曳光起点额外抬高 0.25 米。这些共享修正保持权威伤害和弹道规则。

| 改动文件（共 12 个产品文件） | 本轮内容 |
|---|---|
| [Tank.tscn](G:/AIRTS/AI_RTS/source/match/units/Tank.tscn)、[HeavyTank.tscn](G:/AIRTS/AI_RTS/source/match/units/HeavyTank.tscn) | 标定普通坦克实炮口；重坦加入左右挂点并选每侧上口 |
| [AntiGroundTurret.tscn](G:/AIRTS/AI_RTS/source/match/units/AntiGroundTurret.tscn)、[MachineGunTurret.tscn](G:/AIRTS/AI_RTS/source/match/units/MachineGunTurret.tscn) | 各自真实左右炮口，保留逐发交替 |
| [AntiAirTurret.tscn](G:/AIRTS/AI_RTS/source/match/units/AntiAirTurret.tscn)、[Helicopter.tscn](G:/AIRTS/AI_RTS/source/match/units/Helicopter.tscn) | 分别选择每侧单枚导弹出口和每侧上管，加入左右挂点 |
| [Sniper.tscn](G:/AIRTS/AI_RTS/source/match/units/Sniper.tscn)、[Rocketeer.tscn](G:/AIRTS/AI_RTS/source/match/units/Rocketeer.tscn)、[InfantryAnimationDriver.gd](G:/AIRTS/AI_RTS/source/match/units/InfantryAnimationDriver.gd) | 删除狙击兵旧上偏；允许明确选择枪械最长轴出弹端，火箭兵指定前端，默认步枪拾取不变 |
| [Rocket.gd](G:/AIRTS/AI_RTS/source/match/units/projectiles/Rocket.gd) | 根节点放到发射世界原点，Curve 点用 to_local 写入、to_global 读取 |
| [ProjectileVisuals.gd](G:/AIRTS/AI_RTS/source/match/units/projectiles/ProjectileVisuals.gd) | 回放瞄准点不重复加 0.3 米 |
| [ProjectileRuntime.cs](G:/AIRTS/AI_RTS/source/csharp/GodotAdapter/Combat/ProjectileRuntime.cs) | hitscan 曳光起点直接使用权威枪口坐标 |

测试变更：[MuzzleDisciplineTest.gd](G:/AIRTS/AI_RTS/tests/automated/MuzzleDisciplineTest.gd) 增加多管覆盖并按世界坐标读取 Rocket 点；新增 [_ProjectileOriginVisualProbe.gd](G:/AIRTS/AI_RTS/tests/automated/_ProjectileOriginVisualProbe.gd) 和 [_ProjectileOriginBattleProbe.gd](G:/AIRTS/AI_RTS/tests/automated/_ProjectileOriginBattleProbe.gd) 及对应场景。没有放宽旧失败断言。相对本任务保存的旧文件快照补丁见 [patch-from-task-snapshots.diff](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/final/patch-from-task-snapshots.diff)；其中不包含没有完整任务前快照的共享三文件/直升机，不能把整个 git HEAD diff 都归于本轮。

性能检查：没有新增按单位相乘的搜索、GPU 同步读回、无界缓存或每帧网格扫描。模型顶点提取只在诊断探针中；产品只是静态挂点、初始化端点选择和已有投射物路径的坐标变换。

## 数值：旧挂点与最终实口

下表为各 Marker 父节点的局部坐标，不能直接当世界距离；模型缩放/转向通过运行时变换计入。左右符号仅表示两个出口，具体 L/R 命名沿用场景约定。

| 单位 / 父空间 | 修前 | 最终 |
|---|---|---|
| Tank / Geometry | `(0, 0.72, -1.58)` | `(0, 0.720571, -1.535203)` |
| HeavyTank / Geometry | 单口 `(0, 1.85, -1.4)` | 左右上口 `(±0.345102, 1.9473135, -1.2727867)` |
| AntiGround / model | 左右 `(±0.2259, 0.0036, 3.691)` | 左右上管 `(±0.529325, 1.810696, 4.733238)` |
| MachineGun / model | 左右 `(±0.2259, 0.0036, 3.691)` | `(±0.941751, 1.173430, 3.495962)` |
| AntiAir / model | 单口 `(0, 0.55, 0.6)` | 上排中间出口 `(±1.33420, 2.43652, 1.20431)` |
| Helicopter / Geometry | 旧单点；未保留完整任务前文件快照 | 每侧上管 `(±0.76996, 0.295205, -1.01165)` |
| Sniper / 蒙皮实口 | 旧额外上偏 `0.2208m` | 实口中心残差约 `0.000115m` |
| Rocketeer / 蒙皮实口 | 自动选到背喷口，距前口约 `0.998m` | 明确选择前端；残差约 `0.02416m` |
| Infantry / 蒙皮实口 | 默认自动端点 | 保留；残差约 `0.017484m` |

独立最终 probe11：六类车辆/炮塔 Marker 到选定端面中心的**世界距离均小于 0.000027 米**，重坦两侧均约 0.000002458 米。这个数值证明几何位置，不代表录像具有微米级分辨率。步枪兵/火箭兵剩余厘米级误差来自 AABB 横截面中心与真实环口中心差，未伪称零误差。

## 真实 Match、截图和连续录像

正常 `Match.tscn`、PlainAndSimple、两个 HUMAN，通过正常出生链路创建 10 类单位。每种验证 0/90/180 度和各方向三发的坐标/交替规则，然后以真实 `UnitCommandGateway.AttackUnits` 转向并连射两发。HoldFire 拒绝攻击是负测；确实开火后 Stop 的在途弹仍结算。共 20 次命令开火，两个独立运行均 0 failures，全部目标掉血。

- 无头实际引擎 PID **57252**，console wrapper PID 47844，rc=0，44.062 秒，进程清理通过。不能用 wrapper PID 代替真实引擎 PID。
- 后台 GPU 游戏 PID **43132**，rc=0，46.266 秒，cleanup_ok=true，foreground=false。可见数据在 [battle-visible-02/result.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/battle-visible-02/result.json)，身份在 [identity.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/battle-visible-02/identity.json)；汇总见 [battle-summary.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/final/battle-summary.json)。
- 主线已打开 [对地炮塔正面](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/probe/inspect-AntiGroundTurret-front.png)、[重坦正面](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/probe/inspect-HeavyTank-front.png)、[防空正面](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/probe/inspect-AntiAirTurret-front.png)、[直升机侧面](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/probe/inspect-Helicopter-side.png)、[火箭兵](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/probe/inspect-Rocketeer-front.png)、[狙击兵](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/probe/inspect-Sniper-front.png)。重坦采用最终从 -Z 正前拍摄的图片；早期从后面拍的同名版本不是证据。两张步兵手动 Fire 静态图不能单独证明真实攻击瞬间，配合独立蒙皮采样和命令录像。
- [origins-02.mp4](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/video/origins-02.mp4) 已回看 0–39.4 秒全部 17 张联系表。15 FPS、592 帧、0 重复、所有帧 foreground=false。20 次开火均覆盖。录像器 rc=2、partial：请求 40 秒，游戏正常退出导致最后约 0.5 秒窗口消失。不是绿码录像；限制及逐单位秒数在 [video/review.md](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/video/review.md)。

独立 reviewer 全程只读产品，另建真实 Match 网格/蒙皮探针，最终 rc=0。报告见 [independent-review-final.md](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/reviewer/independent-review-final.md)。实际 C# LaunchGround 与 GDScript 回放挂点规则各发四次，五类双挂点均 L/R/L/R，差 0；这是单进程规则比较，不是双进程 RPC 测试。

## 测试命令、rc 与失败分类

构建已执行 `dotnet build OpenRTS.sln --no-restore --nologo`：rc=0，0 warnings、0 errors；原输出在任务工具调用中，未伪造额外 build 日志。

最终四项由定向运行器记录，结果在 [round-06/gate/summary.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/round-06/gate/summary.json)。对应复验命令为 `python tools/run_targeted_godot_tests.py --godot G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe --ids muzzle-discipline,projectile-guidance,heavy-tank-howitzer,infantry-anim-driver --out agent/runs/20261010-projectile-origin/round-06-replay`；此命令是可复现参数，原始四项调用的完整 argv 未另外持久化，不把它冒充新跑结果。

| 验证 | rc / 结果 | 限制 |
|---|---|---|
| muzzle-discipline | 0，0 failures | 退出有 ObjectDB/RID/resource leaks；严格日志门禁不绿 |
| projectile-guidance | 0，0 failures | 未撤销“仅防空追踪”规则 |
| heavy-tank-howitzer | 0，0 failures | 退出有 leaks；严格日志门禁不绿 |
| final geometry / round-05 | 0 | 真实 Match 的 Marker/Body/Path 与实口检验 |
| battle-headless / battle-visible-02 | 各 0，0 failures | command-level，未证明玩家 UI |
| 独立 probe11 | 0 | 单进程、正常 Match 几何/蒙皮和挂点规则 |
| infantry-anim-driver | 1 | 两项失败；旧驱动对照也 rc=1，见下 |
| projectile-lifecycle | 1 | S0 修前即 rc=1，见下 |
| tank-ordinary-attack | 1 | 旧 Marker 对照同失败，见下 |

已建立针对性旧版本对照的三项：

1. **infantry-anim-driver**：最终测试“位移 >1m”实测 0.96m，以及射程外追击 Run/Fire 判断失败。诊断保持正常 Infantry 场景，入树前替换成任务保存的旧驱动；[infantry-baseline-03/godot.log](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/infantry-baseline-03/godot.log) 同样 0.96m 和同一追击失败，实际 PID 58084，rc=1，26.5 秒，cleanup_ok=true。证明不是新增端点分支造成这两项差异，不证明移动/动画系统整体正确。
2. **projectile-lifecycle**：任务 S0 [baseline/summary.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/baseline/summary.json) 已 rc=1，直升机实测伤害 1.04，而测试期待基础值 1.0，涉及成长倍率。未改判据。
3. **tank-ordinary-attack**：测试发攻击命令后立即 Stop，首发尚未对准便取消。旧 Tank Marker 快照对照 [baseline-stop/result.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/round-02/baseline-stop/result.json) 同样 rc=1。新真实攻击探针先等到实际发射再 Stop，已发弹体能伤害，不用旧测试的立即 Stop 轨迹证明在途弹被删。

两次失败的旧驱动探针搭建尝试（克隆场景路径不被 catalog 认可、factory 返回类型未声明）仅是诊断工具失败；不作为产品基线证据。

全量命令：

```powershell
python tools/run_parallel_suites.py --godot G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe --ids all --jobs 3 --out agent/runs/20261010-projectile-origin/full-regression
```

全量**首轮全部 123 套已运行**，88 通过、35 失败或超时，墙钟 1588 秒。随后完成 9 项失败串行复核：adjutant-observation 恢复通过；adjutant-command-protocol、adjutant-rules-export、background-music、balance-config-runtime、vehicle-factory-worker-production、economy-account、infantry-anim-driver、infantry-queue 仍失败。按运行器成功 marker/rc 口径暂计 89/123 通过；另 26 项失败未完成串行复核，不能判成并发假红或新回归。当前日志同时无 forbidden 命中的有效通过项仅 54，严格全项目门禁不绿。

为结束本轮、避免继续长时间复跑未定位且不在炮口修复范围内的系统，已在确认 S3 红后终止本任务的复核运行器 PID 9812 及当时唯一经身份确认的子 Godot PID 54564（air-entity-move 复核）。工具返回 rc=1，是**主动结束复核进程后的返回码，不是自然跑完的最终 suite rc**。尚余串行复核明确标未完成。身份/范围记录：[owned-stop.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/full-regression/owned-stop.json)，工具返回：[runner-exit.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/full-regression/runner-exit.json)，完整盘点及待复核列表：[audit.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/full-regression/audit.json)。运行器未持久化每个串行复核的单独 rc，报告不从 marker 反推；它还会覆盖失败首轮日志，审计已标明这个证据限制。

启动时清单为 123 套；收尾配置已有 124 项，其中新 icon-size-standard 不在本次启动清单。运行器读入后固定清单，不能把后来新增项误报已运行。全量日志目录：[full-regression](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/full-regression)。除上述三项有修前/旧文件对照外，其余红项未完成修前对照，**均保持未分类**，不统称旧问题、不扩范围改动。

运行器当前 `passed` 仅检查 rc 和成功 marker，`forbidden_hits` 单独记录；即使某套显示 passed=true，也不等于 RSI 的严格“无 forbidden output”门禁通过。

## RSI 决策与剩余范围

局部探索经历 shared 坐标一致性 → 模型实口 → 端面连通组件/蒙皮。早期仅 Marker 一致的候选不能解决截图根因；对地炮按 x 正负平均混入中央低口、重坦每侧上下口平均、直升机整个 gun/rack 平均都被几何复核拒绝，最终用单组件实口。

最后 round-06 的局部目标优于任务前状态，但相关红项、严格日志红项和全量复核不完整使 S3 不绿，**不晋级全项目 champion**。基线本身也非全绿，不虚构一个通过 S3 的旧 champion。本任务没有完整的逐轮全局晋级记录；把共享坐标阶段与 round-02 至 round-06 的六个候选阶段按最终门禁补记，全局连续未晋级为 **6 轮**。这是保守的收尾计数，不是假称每轮当时已保存正式晋级记录。期间已从坐标一致性换到模型实口，再换到独立端面/蒙皮；最终结束编辑并转入记录/复核，不能把局部改善写成全局晋级。正式 candidate/champion 数据在 [champion.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/champion.json)，问题表在 [checklist.md](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/checklist.md)。

未验证/未通过项：玩家点选与右键输入链路；正常菜单退局重开；双进程网络 RPC；中途加入或单位未生成时 fired 事件导致的挂点相位差；全量未分类红项和未完成的串行复核；退出 leaks 和部分诊断日志警告；APC 无实枪口（按用户选择保留）；步枪兵和火箭兵剩余厘米级截面偏差。最终仅查询本轮登记的 18 个 PID，全部已退出，见 [cleanup.json](G:/AIRTS/AI_RTS/agent/runs/20261010-projectile-origin/final/cleanup.json)。没有批量结束用户实例，没有发布成品。
