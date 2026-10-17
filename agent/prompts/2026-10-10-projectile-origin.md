在 G:/AIRTS/AI_RTS 工作。先读 AGENTS.md、工作区边界、闭环验证、RSI 和 agent/manifest.json，并运行实际目标身份检查。用户反馈炮弹与子弹发射位置错乱；先看当前报告 agent/reports/closed-loop/2026-10-10-projectile-origin.md，不重复最初仅检查 Marker 的诊断。

用户明确选择保留装甲运兵车模型，本轮只处理其他武器。不得补 APC 机枪、撤销“只有防空追踪”、改变普通炮弹爆炸范围/权威伤害、重构攻击或移动系统，也不要修改成品。

已修候选有三层：当前模型实际单个端面的 Marker；步兵蒙皮枪口（狙击兵删除0.2208m上偏，火箭兵 muzzle_axis_end=1）；共享坐标（Rocket Curve3D 写to_local/读to_global，回放 aim 不重复抬高，hitscan tracer 从真实世界枪口开始）。多个管口/导弹不能取整个 mesh 或 rack 的平均中心，必须验证独立端面。重坦每侧上下两个端口选上口；直升机每侧双管选上管；防空每侧十枚选择上排中间。

继续本任务时先核对 agent/runs/20261010-projectile-origin/final/source-hashes.json，保留共享树其他修改。产品冻结时只处理报告与回归；出现 hash 变化先查归属。最终真实 Match 几何 probe11、后台连续录像及20次命令攻击已通过局部目标；这些不是玩家 UI 或双进程 RPC 验收。

必须区分已有证据中的红项：projectile-lifecycle S0已有伤害1.04/期待1.0；tank-ordinary-attack 立即Stop的旧Marker对照同失败；infantry-anim-driver 旧驱动对照也0.96m/追击动画失败。其余全量红项未做修前对照，不能一律叫旧问题，不能靠改断言过关。

如需新补丁，保存本轮精确快照，单项编辑后编译，在新独立进程加载正常Match，复验实际实口、Marker、Body/Path/Tracer、不同朝向、双管交替、HoldFire拒绝和真正发射后Stop的伤害。录像采用后台屏外窗口独立捕获，不移动光标、不抢焦点、不注入系统输入；日志、JSON、截图验证mtime后实际打开。相关回归及独立复核、全量结果写进报告，保持未验证项和 needs-review 状态直至严格门禁通过，不声称全项目完成或伪造 champion。
