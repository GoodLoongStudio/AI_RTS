# 小部队个位数 FPS：诊断、补丁与验证

状态：**目标性能已验证；整体 needs-review，不宣称全项目全绿。**

## 结论

主要瓶颈是 `Movement._on_velocity_computed → _push_out_of_static_obstacles`，
不是“几十个单位模型本来就画不动”。每单位每次避障回调，对每个大障碍重新遍历
自己的 GeometryInstance/骨骼、求近地 hull，同时重复查障碍碰撞形状；最后才拒绝远障碍。
静止单位也会收到回调。原 `G4PERF movement_us` 只包 `_physics_process`，漏掉了此热点。

## 已实施

唯一产品算法改动：[Movement.gd](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:1036)。

- 当前姿态的近地骨骼点/模型角点在**一次同步推出调用内**仅采样一次，再按各障碍原方向投影。
- 原距离门禁先拒绝不可能推出的障碍，再查询当前位置的 inside/escape 状态。
- 不跨帧缓存，不简化朝向，不用一个圆半径替代 OBB，不改变半径、净空、窄口、出生或到达规则。
- 没有降画质、关闭避障、降低模拟频率、改速度/尺寸/射程/视野。探针解锁 FPS 只影响它自己的进程。

同时增加冻结原算法对照、等价夹具、可见性能探针、带 Instance 生命周期的运行器和回归入口。
运行器检测 fresh JSON/PNG、退出码、解析/脚本错误及有效阶段最低平均 **27 FPS**。
诊断用断开回调阶段不作为性能达标的依据；所有回调最终恢复。

## 数值

负载：PlainAndSimple 真实 Match，46 新混合单位 + 5 车厂 + 2 开局实体 = 53 实体。
最新运行记录 47 个 mover、6 个地面障碍。窗口可见，镜头覆盖部队，RTX 3080 Ti / Ryzen 5900X。

| 阶段 | 原算法 FPS | 同夹具补丁 FPS | 帧时间 p50：原 → 补丁 |
|---|---:|---:|---:|
| 正常回调 | 4.386 | 147.982 | 213.901 → 2.905 ms |
| 断开回调（只隔离热点） | 344.207 | 281.827 | 2.217 → 2.347 ms |
| 恢复回调 | 4.735 | 108.956 | 207.171 → 11.348 ms |
| 部队移动 | 4.474 | 104.992 | 202.304 → 11.562 ms |

上述严格对照的车厂是施工外观。随后补齐完整建筑表现并复测：

| 最新完整建筑重放，14:43:01 | 平均 FPS | 帧时间 p50 / p95 |
|---|---:|---:|
| 正常回调，无上限 | 109.227 | 11.534 / 17.176 ms |
| 恢复回调，无上限 | 85.535 | 13.218 / 23.299 ms |
| 移动，无上限 | 91.502 | 12.586 / 22.872 ms |
| 正常 30 FPS 上限 | 29.812 | 32.968 / 53.972 ms |

不能把 29.8 FPS 说成毫无尖峰；当前 30 FPS 样本 p95 仍约54 ms。
该补丁消除了已复现的持续个位数卡顿，不证明数百单位、长时间副官/模型服务或大量交火全部达标。
FPS 依据 process_frame 的真实墙钟间隔；内置 process/physics/nav monitor 仅作辅助，不当作互斥耗时相加。

## 证据与复现

原截图局已退出；使用新真实 Match 复现，而非把旧截图当运行记录。
`before/` 早期夹具存在 current_scene/镜头问题，已明确拒绝，不引用其高 FPS。

- [有效原算法 JSON](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-small-army-performance/before-visible/summary.json)
- [同夹具补丁 JSON](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-small-army-performance/after-round1/summary.json)
- [最新完整建筑 JSON](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-small-army-performance/after-replay-current/summary.json)
- [最新截图，已打开检查](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-small-army-performance/after-replay-current/army.png)
- [独立手算运行验证](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-small-army-performance/independent/verification.md)

截图中部队、完整车厂、基地、资源、阴影、战争迷雾和 HUD 正常显示；不是黑屏/关模型的高 FPS。

```powershell
$env:AIRTS_GODOT='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
python tools/dev/small_army_performance.py --out agent/runs/perf-replay
python tools/dev/small_army_performance.py --equivalence --out agent/runs/push-equivalence
```

## 回归与限制

新旧推出输出 **5,959 项对照，0 失败**；覆盖偏心嵌套缩放盒、四个 yaw、inside/escape、
两个连续障碍、方向不对称 hull、零 hull 回退、窄口、骨骼/姿态变化与过滤节点。rc=0。
独立夹具不用主线 oracle，以手算点集验证 **340 项，0 失败**；Godot/驱动 rc=0、fresh=true、无错误。

相关12套件：运行器报告9/12；导航稳定、局部避让、移动尺度、强制移动、落点、尺寸和形状等通过。
但是 unit-radius-coverage / narrow-passage 带 SCRIPT ERROR，不把这种“有完成标记”的结果当严格通过。
以下三类真实失败已串行复查，并用旧算法的独立副本重放，未改产品代码/断言：

| 套件 | 补丁 rc | 旧算法副本 rc | 一致失败 |
|---|---:|---:|---|
| worker-gather | 1 | 1 | 资源耗尽后的末次交付3条 |
| spawn-point-regression | 1 | 1 | Worker入队/产出2条 |
| movement-recovery | 1 | 1 | 新建建筑后未到达2条；误差11.71 / 11.69m |

movement-recovery 在后续 full-rest 串行运行又通过（rc=0，49.4s），没有改产品/断言。
因此该项记录为不稳定复现/时序风险，不把它误称为始终失败的确定性新回归。

全量选择117套件，分 full / full-rest 两段，已有多个配置、UI、资源/脚本及超时失败。
117项都有完成日志：86项含预期成功标记，只有53项同时无配置中的禁用输出。
这是日志审计计数，不代替每项进程rc；full-rest运行器为25/33、整体rc=1。
除上述已作旧算法对照的三项外，其余全量失败未逐项归因，不能笼统称为“都与本补丁无关”。
具体日志审计见 [strict_log_audit.json](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-small-army-performance/strict_log_audit.json)。
标准 runner 的 passed 目前忽略 forbidden_hits；本报告把 marker 和禁用输出分开，不沿用假绿。
超时和两段执行边界见 [full-budget.md](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-small-army-performance/full-budget.md)。

## 工作区与决策

仓库原本有大量他人 staged/unstaged 修改；未回滚、清理、提交或覆盖它们。
期间其他工作重编译了 C#，一次旧算法副本启动失效，已保留但不作为比较证据；之后有效重跑。
最终补丁 Movement SHA256：`86B1F0A63B79848B7CB1CE76F396BB09949B0223246C4D31A0692DDE1BF9013A`。
14:26 后 C# DLL稳定；最新性能重放在14:43完成。所有己方可见/独立/基线探针已正常收尾。

一轮产品候选获得约20倍以上目标场景改善；没有第二轮盲调。全局连续未晋级1轮。
**不提升为全项目 champion**：性能和几何目标通过，但全局硬门禁未全绿；保留已验证补丁并标 needs-review。
后续优先处理测试假绿/启动错误、上述三个旧失败，再扩到100/200单位与副官持续运行压力验证。
