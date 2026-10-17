# 战区补给真实加成专项

日期：2026-10-11。状态：**专项断言通过；整体 `needs-review`，不作为发布通过证明。**

## 用户目标与边界

截图中的战争路径、要塞化、高效开采，以及现有其余卡牌，选中后必须改变真实玩法结算，不只是显示倍率。保留 `config/match_augments.json` 的 12 张卡及原平衡数值。

开发根 `G:/AIRTS/AI_RTS`，Git HEAD `9a2e6d449185760f9219854c538f3b672a027bf2`，工作树含大量其他任务修改。开发目标检查 rc=0；所有探针显式 `--path G:/AIRTS/AI_RTS`。未改打包版、摄像机、模型、卡面、用户实例或单位平衡。

## 诊断与实际改动

基线不是“所有单机卡都是假的”：修前逐卡探针已测到伤害、资金、交货和视野生效。确证缺陷是作战生命误作用于矿车、HP 重算误广播受伤，以及联机缺少补给权威交互和上限同步。

| 文件 | 本任务范围 |
|---|---|
| `source/match/augments/AugmentModifiers.gd` | 作战 scope 排除非战斗工人；忽略死亡/销毁单位；基线幂等计算；HP 保持比例且不用受伤 setter；客户端不重算权威当前 HP |
| `source/match/augments/AugmentRuntime.gd` | 客户端选择/推荐可靠 RPC；服务器绑定 sender 的真实玩家槽位，校验卡/轮次/截止时间；已选效果公开同步、未选 offer 仅本人可见；倒计时传剩余时间；资金事务成功才消费卡；首次状态补发；统一出生继承 |
| `source/net/NetSync.gd` | 新增 `hp_max` 快照，先上限后当前 HP；提供收到权威快照的就绪查询。既有维修状态同步不是本任务改动 |
| `source/match/units/Unit.gd` | 配置与成长完成后，在网络快照到达前建立加成基线并应用已选卡。只新增该入口，保留该文件大量既有修改 |

独立复核找到并已修正两类候选漏洞：客户端快照先到时把 108 当作基线又乘 1.35 得到 145.8；补发依赖仅服务器设置的 `_live`。最终以配置基线 80 和已收到权威快照作为口径。另补齐过期推荐 RPC 的 deadline guard，防止超时后改变自动选牌排名。

新增维护入口：`AugmentMatchFixture.gd`、`MatchAugmentEffectsTest.gd/.tscn`、`MatchAugmentNetworkTest.gd/.tscn`、`tools/run_augment_verification.py`。全部在真实 Match 场景中运行；无假单位替代伤害或经济账户。

## 真实测量

下表是同类未加卡与选卡后的实际结算，不是声称修前所有数值为零。

| 卡牌/组合 | 实测 |
|---|---|
| 战争路径，伤害 +25% | 真实 C# 弹体命中扣血 `0.5 → 0.625` |
| 锐利武器，伤害 +15% | `0.5 → 0.575` |
| 要塞化，建筑最大生命 +35% | `80 → 108`；原半血 `40 → 54`，仍为 50% |
| 加固工事，建筑最大生命 +20% | `80 → 96`；原半血 `40 → 48` |
| 两张作战生命卡 | 坦克上限 `10 → 11.5 / 12.5`；矿车不受作用 |
| 高效开采，交货 +25% | 正常 Gather 命令采集 40 矿，返矿场后权威账户到账 `50` |
| 另一张交货 +50% 卡 | 同样 40 矿，到账 `60` |
| 两张赠款卡 | 每张准确入账 `5000`，重复选择不重复入账 |
| 两张视野卡 | `16 → 20 / 24`；真实视野边界从不可见到可见 |
| 成长伤害 +20% × 战争路径 +25% | 真实扣血 `0.5 → 0.75`，新生单位倍率 1.5，复算三次不重复叠加 |
| 成长建筑生命 +25% × 要塞化 +35% | `80 × 1.25 × 1.35 = 135`；半血为 `67.5` |
| 成长交货 +25% × 高效开采 +25% | `40 × 1.5625 = 62.5`，按现有取整口径实际到账 `63` |

12 张卡均逐张测试；检查已有/新生单位、新建筑、敌人不变、重复选择拒绝和 HP 重算无受伤通知。Growth 合成测试只改测试进程内的等级并还原，不调用存档保存。

## 证据与复跑

在开发根执行，`$g` 指向已有 Godot .NET 4.7.1，输出目录必须是新目录：

```powershell
$g = 'G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe'
dotnet build OpenRTS.sln --no-restore --nologo
python tools/run_augment_verification.py --godot $g --mode effects --rendered --out agent/runs/<new-effects-dir>
python tools/run_augment_verification.py --godot $g --mode effects --out agent/runs/<new-headless-dir>
python tools/run_augment_verification.py --godot $g --mode network --rendered --out agent/runs/<new-network-dir>
```

| 运行目录，均在 `agent/runs/` | 结果 |
|---|---|
| `20261011-augment-effects-baseline-certified` | 修前 rc=1；两条工人误加 HP，一条 HP 重算误发受伤；其他实际伤害/交货数值已有生效 |
| `20261011-augment-effects-r5-growth` | rc=0，12 卡 + 成长合成均零断言失败；GPU 日志无 ERROR/禁用输出；约 11.91 秒；cleanup_ok=true |
| `20261011-augment-effects-r5-headless` | rc=0，同一真实 Match 专项；约 11.08 秒；6 次既有 Minimap Dummy texture 错误，不能称全日志干净；无其他引擎错误，cleanup_ok=true |
| `20261011-augment-network-r5-permanent-boundaries` | runner/server/client rc=0，GPU 日志干净，cleanup_ok=true；五类效果、私有 offer、伪造/旧轮次/重复请求、状态补发、过期选择及推荐拒绝 |
| `20261011-augment-independent-r4-fixed` | 独立探针双方 rc=0；108/54 快照先于 owned 仍保持 108/54、baseline80；首次补发触发；截止后 29ms 推荐 RPC 被拒；每端6次已知 Dummy 错误，无其他 ERROR |

最终数据：[逐卡与成长 JSON](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-effects-r5-growth/effects.json)、[联机服务器 JSON](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-network-r5-permanent-boundaries/server.json)、[独立复核](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-independent-r4-fixed/review.md)。console wrapper PID 与实际 Godot Mono PID 分别记录在 summary 和结果 JSON，不能混同。

最终截图已实际打开查看，mtime 为 2026-10-11 00:39:20，属于本次新进程：

- [选择前](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-effects-r5-growth/draft-before.png)：三卡及原数值可见。
- [选定要塞化](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-effects-r5-growth/citadel-selected.png)：弹层关闭，左上已有卡托盘，基地选框/血条和单位正常渲染。

截图为隔离桌面上的真实 GPU 实例。测试临时关 fog 并定位场地边缘以取图，左侧黑色是机位越界，不是本任务修改的产品视野。截图不证明伤害/交货，通过 JSON 和真实逻辑断言确认。

辅助控制台隐藏；没有 SwitchDesktop、抢前台、系统鼠标/键盘注入或终止用户实例。最终 CIM 核查无本轮测试残留，其他仍在运行的 Godot 不属于本任务，保持不动。`dotnet build` 最终 rc=0、0 警告/0 错误；限定文件 `git diff --check` rc=0。GDScript 均由实际运行场景加载校验。

## 相关回归未全绿

`20261011-augment-regression-final` 串行跑 20 项 GPU 回归，runner **rc=1**，cleanup_ok=true。14 项退出码/marker 通过，只有 6 项同时日志干净。不得把“rc0”或“0 failure”与完整日志门禁通过混同。

```powershell
python tools/run_augment_verification.py --godot $g --rendered --mode regression --ids match-augments,balance-config-runtime,economy-account,csharp-command,client-hp-first-sync,presentation-sync,death-cleanup,unit-registration-consistency,damaged-health-bar-persistent,enemy-health-bar,health-bar-flicker,production-queue,projectile-lifecycle,projectile-guidance,tank-combat-policy,worker-gather,fog-of-war-sight-range,structure-repair-sell,structure-repair-rate,ore-refinery --out agent/runs/<new-regression-dir>
```

| 套件 | rc / marker | 未通过原因 |
|---|---|---|
| balance-config-runtime | 1 / fail | Tank 成本/视野/速度、Worker 载荷断言失败 |
| economy-account | 1 / fail | Legacy 镜像及拒绝交易后资源断言失败；退出泄漏 |
| enemy-health-bar | 1 / fail | 敌方血条颜色断言失败；退出泄漏 |
| projectile-lifecycle | 1 / fail | 发射者死亡后弹体伤害断言失败 |
| worker-gather | 1 / fail | 最后交付完成订单及耗尽待机两条断言失败；退出泄漏 |
| ore-refinery | 0 / 缺 marker | 无预期完成 marker，不能按退出码判通过；退出泄漏 |
| csharp-command、death-cleanup、tank-combat-policy、unit-registration-consistency、match-augments、fog-of-war-sight-range | 0 / pass | 六项日志门禁也通过 |
| damaged-health-bar-persistent、health-bar-flicker、production-queue、projectile-guidance、presentation-sync、structure-repair-sell、structure-repair-rate、client-hp-first-sync | 0 / pass | 仍有退出泄漏、离树 transform 错误或夹具缺节点/SCRIPT ERROR，日志门禁失败 |

原始 [summary](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-regression-final/summary.json) 与逐项日志保留。上述失败**尚未逐项进行同树修前/修后 A/B 归因**，不能宣称全是历史问题，也不能据此说全由补给改动引起。没有放宽断言或顺便修改经济/血条/采矿其他产品逻辑。

早期 `growth-modifiers` 旧套件虽打印 `failures=0`，仍有预期 marker 空格不匹配、未转义 `%` 格式错误及退出泄漏，不算干净通过。没有修改旧套件来凑绿；最终新增不落盘的真实成长合成验证补充本任务契约，但不代替全部成长系统验收。

## 候选与停止决策

轮次记录为基于保留产物整理的审计索引，不伪装成每轮预先生成的 Controller 日志：

| 轮次 | 方向与结果 | 决策 |
|---|---|---|
| R1 | 工人作用域及 HP 无受伤更新；基线3失败变专项0失败 | 专项候选改善；旧成长日志仍不满足整体门禁 |
| R2 | ENet 权威选择/同步；客户端初始化补发仍失败 | 不晋级；换初始化顺序诊断 |
| R3 | 配置基线先捕获、用已到快照触发补发；独立复核发现过期推荐可改 rank | 不晋级；换 deadline 边界诊断 |
| R4 | 补 deadline guard；主线与独立同 RPC 轨迹通过 | 专项目标通过；20项相关回归阻止整体晋级 |
| R5 | 测试加固：成长合成、将截止拒绝写入常驻联机测试，无产品改动 | 专项持续通过，停止扩展编辑，整体保留 needs-review |

没有可证明全量门禁通过的新 champion。R1-R4 四个产品候选均未完成全局晋级，已超过三轮饱和阈值；期间切换了诊断方向，本轮不继续盲目打产品补丁。保存候选 hash 与证据于 [champion.json](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-effects-r5-growth/champion.json)，`promoted=false`；[checklist](G:/AIRTS/AI_RTS/agent/runs/20261011-augment-effects-r5-growth/checklist.md)。未粗暴回滚共享工作区来伪造全绿。

## 未验证与后续

本任务是 command-level/真实 Match 逻辑专项，选牌通过实际 overlay 信号链，并非完整 OS/UI 玩家试玩。未录连续视频，未验证正常鼠标点卡/键盘1-3全流程、菜单退局重开、公网延迟/丢包、完整120+回归、全部永久成长存档路径、千单位性能或打包版。截图不替代这些范围。

后续先逐项归因回归红项并验证共享工作树，再决定发布；不要因为本报告补给专项通过覆盖评审成品。任务提示词与计划已同步，最重要的不变量是**配置基线 × 成长 × 已选卡只计算一次，客户端当前 HP 只接受权威快照**。
