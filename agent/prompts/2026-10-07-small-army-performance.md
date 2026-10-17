# 性能定位执行提示词

按 skills/闭环验证工作法.md 和 skills/AI_RSI自校验循环.md 执行 agent/plans/2026-10-07-small-army-performance.md。先测后改，保持画质、碰撞/避障语义及模拟频率；测试实例仅用 tools/dev/match_instance.py 的动态端口、租约和进程树生命周期管理；拒绝用删除玩法换取帧率。
# 接手时先读结论

读取 agent/reports/closed-loop/2026-10-07-small-army-performance.md 和对应 checklist/champion。
本轮不是全项目全绿：53实体的小部队持续掉到4~5FPS的主要热点已定位并精确优化，
最新完整建筑移动91.5FPS，正常30FPS上限29.8FPS；仍有其他失败待单独诊断。

不要把旧失败或脚本错误冒充新回归，也不要把有成功marker但含forbidden输出的测试报绿。
先核对 Movement hash 与当前C#DLL/配表；共享工作区重编译时的启动证据无效。

复现命令：先设置 AIRTS_GODOT，再运行
`python tools/dev/small_army_performance.py --out agent/runs/perf-replay`。
它要求 fresh JSON/PNG、无脚本/解析错误、有效阶段平均>=27FPS，自己的Instance必须finally.stop。
断开velocity callback仅用于隔离热点，不是允许交付关闭碰撞的版本。

范围纪律：保留一次push内采样复用及逐方向support；不得跨帧缓存骨骼世界点，不得用单一半径
错误拒绝偏心/旋转OBB，不得用降画质、关避障、缩碰撞、改速度或降物理tick掩盖热点。
测量必须包括velocity_computed callback，原physics_process单点计时不覆盖它。

下一步优先：测试runner假绿/启动错误；采矿最后交付和Worker生产旧失败；新建筑移动收敛时序。
每次只选一个可证伪方向，从新鲜真实Match出发，做旧/新对照，打开截图，再跑相关与全量回归。
完成后才扩大100/200单位及副官长局压力验证；当前53实体通过不等于这些场景已经达标。

