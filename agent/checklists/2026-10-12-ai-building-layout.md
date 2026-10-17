# 验收清单（R23产品 / R24验证器）

2026-10-12 19:43：用户要求移交Cursor，自有回归进程已清理；旧等待/冻结解除。[接管提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-cursor-takeover-building-adjutant-and-performance.md)。整体仍needs-review。

- [x] 主工程定位及实际源码目标检查rc0，保留共享修改和原始字节/hash。
- [x] 共用选址分散/生产出口/双向采矿通道；真实Match最小逻辑radius边距≥5.6m。
- [x] 远距慢施工排除自身与在建基地、小数工量；25.3526m118ticks、105.375m500ticks，25m已非全速。
- [x] 自然电脑资源扩张及矿场/对地对空防御/主基地生产角色；最终当前版本独立自然局两基地81.0873m、远矿59交货23600矿、AA/AG各1、生产home无违例。
- [x] 副官导出→Python规则/模拟模型四列BLD→真实命令13阶段，逐矿场交货与坦克通行（稳定R16/R17/R18/R21）。
- [x] 贴建筑角落卸货、矿车服务矿点方向安全出生与普通生产local+Z回退独立边界。
- [x] 动作延迟owner解析/同步终态信号/目标丢失、正常退局重开（R16/R17独立）。
- [x] 开局基地/紧急运动状态/seen_arrivals跨JSON与图通道往返；旧checkpoint迁移与256上限。
- [x] 到达和失败事件按真实发生tick/目标关联；上一段迟到事件不作废下一段。
- [x] 实际Movement8条终态有界缓存→DCS正常采样，原生两腿侦察S1与旧交矿/重开。
- [x] R21GPU110秒5FPS实际回看home/remote/tank共182密帧，所有帧foreground=false。
- [x] 副官声明运行时完整1045tests，1044pass/1skip，rc0及Pythonhash稳定；Laya路由/降级/熔断模拟回归通过。
- [x] 独立Python12边界用例通过，包括其自行发现的旧path_failed反例。
- [x] 当前原生终态环/延迟采样/Unreachable/实例游标、生命周期和自然扩张独立真实Match（三局rc0，同149产品hash与2DLL稳定）。
- [x] 验证器相对APPDATA导致DirAccess扫描8项假红：同源码绝对路径0失败；只修regress.py输出resolve，原失败保留、旧自有进程清理通过。
- [x] 自有runner/子进程按身份停止，watchdog退出；最新部分审计与78项失败索引已保存，原日志保留。
- [ ] 127Godot初跑完成；78失败项串行已完成75，严格49通过；剩余3项移交中断，由Cursor按需补验，原r24不伪造final。
- [ ] R25三处主测试修正待Cursor落地并复跑；HUD地图内+Z14m及物理步受控独立58断言通过，复制证据不等于主测试成绩。
- [ ] S3全部相关门禁与全局champion；若未通过保持needs-review。

未纳入通过范围：玩家鼠标UI资格、音效、真实GPU小模型推理、多地图大部队性能A/B。5FPS仅录像采集率。并行源码风险按每局hash判断，R22初次GeneratedTerrain更新的混合树结果不晋级；不假定所有会话已停写。

报告：agent/reports/closed-loop/2026-10-12-ai-building-layout.md；checkpoint-r23.json。
