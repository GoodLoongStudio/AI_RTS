# RVO 实施报告的证据复核

状态：needs-review。本轮只读复核和文档交接，没有实施游戏优化或测量新的 FPS。

复核对象：[DeepSeek 实施报告](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-07-rvo-scalability-implementation-report.md)。

## 结论与选择

选择 A，但先纠正测量器，再做真实管道归因。暂不选 B，也不选 C。

当前证据足以说明这套测试下存在极严重的性能问题，但不能推出“原生 RVO 求解占95%”“其他层都已否证”“需要540倍架构提升”“只能换库或下调目标”。RVO 仍是待测热点，不是已被证明无辜；也不能反过来保证1000单位必然能达标。

## 1. 关闭 RVO 同时移除了当前移动的位置落地回调

位置链路如下：

- [Movement.gd:351](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:351) 在导航服务器路径计算 preferred velocity，随后调用 `set_velocity(new_velocity)`。
- [Movement.gd:401](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:401) 将 `velocity_computed` 连接到 `_on_velocity_computed`。
- [Movement.gd:2026](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:2026) 在该回调内旋转、做静态推出并写单位的位置。
- [_RvoIsolationProbe.gd:71](G:/AIRTS/AI_RTS/tests/automated/_RvoIsolationProbe.gd:71) 仅将 avoidance_enabled 设为 false，没有对应的无 RVO 位置更新分支。

日志所用引擎标识是 `v4.7.1.stable.mono.official.a13da4feb`。对应的 [NavigationAgent3D 源码](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/scene/3d/navigation/navigation_agent_3d.cpp) 中，关闭 avoidance 会取消服务端避障回调。因而探针保留了寻路节点，却没有保留这条移动执行路径的完整工作量。逻辑地形/独立空中分支需分别统计，不能把结论扩大到每一种移动域。

OFF 条件减少的不只是求解，还包括该回调里的推出、位置更新及后续移动状态变化。没有记录实际位移，不能证明其余玩法等价；更不能将 ON-OFF 差值全部记给 C++ RVO。

修复诊断器时可以在自有测试开关下补充 preferred velocity 的位置提交，但必须标为“无动态避让的非等价诊断条件”。双方轨迹仍会不同，最终原生求解归因要靠真实调用计时/采样或同输入的核心回放，不能靠这个差值独占认领。

## 2. 所谓回调脚本画像实际没有成功调用两个关键函数

[_ScriptAggProfile.gd:55](G:/AIRTS/AI_RTS/tests/automated/_ScriptAggProfile.gd:55) 将同一个 float delta 传给全部方法；[_ScriptAggProfile.gd:128](G:/AIRTS/AI_RTS/tests/automated/_ScriptAggProfile.gd:128) 执行 `call(method, delta)`。

实际签名分别是 `_on_velocity_computed(Vector3)`、`_nearby_unit_stats()` 和 `_update_recovery(delta)`，不能用统一参数调用。

这不是猜测，已存在真实错误日志：

- [agg2_300_err.log:17](G:/AIRTS/AI_RTS/agent/runs/agg2_300_err.log:17)：float 无法转换为 Vector3。
- [agg2_300_err.log:22](G:/AIRTS/AI_RTS/agent/runs/agg2_300_err.log:22)：`_nearby_unit_stats` 期望0个参数。
- [agg2_1000_err.log:74](G:/AIRTS/AI_RTS/agent/runs/agg2_1000_err.log:74) 和第79行包含同样的两项错误。

stdout 也没有成功的两项 CALLBACK_AGG 成绩，只有 `_update_recovery` 的结果。原报告“含 velocity 回调的31.2ms”“脚本成本仅0.13%”不成立。

即使修对参数，连续手动调用60次 `_physics_process` 也不是实际帧画像：会改变状态、路径和恢复计时，缺少异步/信号/Timer/C#回调，且实际一渲染帧的物理步数未按真实差分加权。`_update_recovery` 已在 physics 内调用，inclusive 结果不能再当 exclusive 加一次。

该工具的第49行还使用 `%20`、3.2m 的旧生成坐标，1000次输入最多400个独立坐标。不能与新32列夹具混作同一负载的归因数据。

## 3. 原始恢复段没有回到基线

同一 [rvoiso_1000.log](G:/AIRTS/AI_RTS/agent/runs/rvoiso_1000.log) 的实际输出：

| 阶段 | frame p50 | frame p95 | 物理步/秒 |
|---|---|---|---|
| ON，日志第13616行 | 17959ms | 17959ms | 0.8 |
| OFF，第16828行 | 854ms | 1640ms | 10.3 |
| 再 ON，第19062行 | 1787ms | 1998ms | 4.8 |

第二个 ON 比第一个 ON 小约10倍。恢复开关不代表恢复拥挤状态、AI任务、路径或负载。原报告“恢复后回到基线”的叙述与原始数字冲突，因此21倍不能当可重复、等状态的原生求解改善系数。

[_RvoIsolationProbe.gd:61](G:/AIRTS/AI_RTS/tests/automated/_RvoIsolationProbe.gd:61) 把所有 movers 派往同一点，属于密集汇聚压力，不是正常1000单位编组通行的基线。其6秒采样窗口在一帧已需18秒时无法保证分位数样本量；代码没有输出样本数与有效性标记。这类结果应记录灾难性长帧/超时，而不能以精确p95建立普遍扩展性定论。

## 4. “没有线程控制API，所以无法并行”错误

[官方 ProjectSettings](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-property-navigation-avoidance-thread-model-avoidance-use-multiple-threads) 提供 `navigation/avoidance/thread_model/avoidance_use_multiple_threads`，文档默认 true。

与日志版本对应的 [NavMap3D 源码](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/modules/navigation_3d/nav_map_3d.cpp) 在构造时读取此设置；`step` 在线程条件成立时通过 WorkerThreadPool 分发避障计算，然后等待任务。求解和回调分发是不同阶段。

这证明“Godot 不支持避障并行”的推论错误，不证明当前实例已经正常利用线程，也不保证开启能提高帧率。接手必须读实际项目值、引擎构建、worker配置和线程采样；设置已是 true 时不要再把 true 写一次称为优化。NavMap 在构造时读取设置，测试应在创建地图前设置或重启独立实例。

Godot 这里已使用原生 RVO 实现、KD-tree 和可选多线程。换到另一个“原生RVO2”不是从脚本算法升级为原生算法，收益必须来自经验证的实现或集成差异。

## 5. set_active(false) 不能证明停止所有寻路查询

[_NavServerIsolationProbe.gd:68](G:/AIRTS/AI_RTS/tests/automated/_NavServerIsolationProbe.gd:68) 的注释称寻路与地图同步全停，但该结论不符合 API 实现。

对应版本的 [GodotNavigationServer3D 源码](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/modules/navigation_3d/3d/godot_navigation_server_3d.cpp) 在 physics_process 中检查 active 并跳过后续地图 sync/step/callback；直接 `query_path` 则走查询实现，不以该 active 标志作入口闸门。physics_process 检查前也仍有命令刷新，process 的 generator sync 是另一入口。

Movement 仍可在脚本中调用 `get_next_path_position` 或其他同步路径/最近点查询。必须统计实际 query 次数与调用栈，不能用服务器开关没收益宣布所有寻路与同步无成本。

## 6. 测试环境和“完全否证”仍有缺口

- [rvoiso_1000.log:4](G:/AIRTS/AI_RTS/agent/runs/rvoiso_1000.log:4) 显示24579端口被占用，本实例调试控制端点未启动；[stderr:1](G:/AIRTS/AI_RTS/agent/runs/rvoiso_1000_err.log:1) 显示MCP9090监听失败。聚合1000日志还含副官探测其他权威端的信息。不能声称干净、实例隔离的基线。端口冲突本身未被证明是18秒长帧根因。
- 用户转述当前 DebugControlServer 有解析错误，本轮没有启动引擎重新证明其现状。接手先校验autoload健康；不能将故障启动作为性能成绩。
- 物理 active objects/pairs/islands 为0，不等于整个PhysicsServer/Area更新/同步耗时为0；相关实体有Area检测语义，要靠阶段计时/采样。
- 静态障碍组只有2至3个成员，只否证“每个mover都注册到该组”。重复遍历昂贵mesh/hull仍可能有代价，须量每次成本和次数；不能仅据成员数否证静态推出。
- 唯一5m网格只是唯一输入坐标。需要检查实际出生结果、hull与玩法圆重叠、地图边界和单位总数，不能把生成尝试次数当成功生成数。
- `17959/33.33` 只是这次场景墙钟与目标预算之比，不能证明架构必须做540倍升级。移除热点后的条件已不等价，且初始ON存在巨大漂移。

因此，渲染/节点诊断的历史数字保留为线索，不把整份“否证清单”视为各层彻底排除的证明。

## 7. 更可能带来结构性改善的顺序

先生成一张可信的真实热点表，不先重写整个系统。根据热点选择：

1. 如果重复几何/推出最贵：稳定静态描述缓存、版本失效和保守 broadphase，避免每单位每步重新取mesh/蒙皮/形状；不能改变碰撞净空。静态组小不阻止此候选，但也不保证它值得优先实施。
2. 如果路径查询最贵：合并同任务的无效重复请求，明确地图/目标变更失效；再评估有边界的路径队列/同组共享。当前 [Movement.gd:435](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:435) 在所谓同目标快路径仍写 target_position；对应引擎 setter 会请求repath，是可测候选，不是本轮确证热点。保留动态路径修复语义，不直接删所有写入。
3. 如果邻居/恢复/索敌最贵：按移动域/队伍使用维护成本受控的空间索引和稳定候选次序，替换全量重复扫描；保留敌我、出生、死亡和边界更新合同。
4. 如果日志/调试/UI最贵：把逐单位打印转为有界采样/聚合，消除错误与跨实例探测。关闭可选调试输出不等于取消玩家反馈；异步TCP等待不直接等于CPU阻塞，需量实际唤醒/处理开销。
5. 如果原生求解确实最贵：先量正常地面2D避障域、真实邻居和空间密度、现有线程状态；构建同输入的纯核心微基准，之后才决定替换或优化具体实现。不要擅自把地面/空中域合并或关掉动态避让。
6. 只有主线程中稳定的纯数学热点确证后，才迁移到现有C#并评估批处理/有界并行；不在worker访问SceneTree、节点变换或骨骼。

编组目标分配和共享Flow Field可能改善军团任务/重复路线，但属于条件性方案。将“1000人必须去同一点”的病态测试改成正常分散目标，只是修夹具，不是已实现产品优化。不能用停止部队、削减视野或关闭碰撞取得假达标。

## 8. 交付、验证与风险

新增本报告、[计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-07-rvo-evidence-correction.md) 和 [DeepSeek纠正提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-07-rvo-evidence-correction-deepseek.md)。保留旧报告，不覆盖其作者记录。

本轮只读证据：源码/hash/mtime、旧stdout/stderr、官方文档及a13da4feb源代码。当前Movement hash为 `B4E4F4A93495209356EEF88E2BCA1E6D97866AA8250B6909025FEDF9AB9FE187`；这次核查时未见9690版本缓存。旧设计报告的版本警告是当时观察，不用于覆盖当前代码。

路径检查命令 `python tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS/agent/prompts/2026-10-07-rvo-evidence-correction-deepseek.md`，rc=0。三份新文档的存在性、本地链接、空白、作用域和Movement hash保护检查rc=0。

没有新的before/after FPS，没有新截图；未执行Godot启动、C#编译、相关/全量回归或独立运行时复核，没有接受产品candidate/champion。本轮修正的是诊断可信度，游戏性能问题仍未解决。共享工作区可能继续变化，接手不得覆盖他人修改。
