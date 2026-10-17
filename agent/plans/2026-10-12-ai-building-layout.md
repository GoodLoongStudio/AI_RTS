# AI 建筑布局、分基地与副官状态闭环

状态：needs-review，已按用户要求交给Cursor接管。R23产品候选、R24验证器环境更正；全项目S3尚未晋级。开发根G:/AIRTS/AI_RTS，定位及源码目标检查rc0；当前交付成品没有更新。

2026-10-12 19:43交接：自有runner及子进程已核验停止，watchdog正常退出；127项初跑完成、78个失败项75个串行复查完成，严格49通过，剩余3项因移交未完成。R25三处主测试修正待Cursor落地，历史全量保留部分完成状态，不伪造final。旧冻结/等待要求解除；[接管提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-cursor-takeover-building-adjutant-and-performance.md)、[最新审计](G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/handoff-audit.json)、[清理证据](G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/cursor-handoff-cleanup.json)。Codex本轮不再写产品或启动测试。

用户目标：电脑玩家与副官建散建筑，保护生产出口和矿车路线；主基地支持远距离慢施工；双方扩张新矿并补防御，普通生产留开局基地。用户已授权本轮同时修复副官状态通道、侦察完成事件和Laya回归失败；OpenCode交接已确认，Cursor也在共享工程工作，保留其改动。

权威来源：C# StructurePlacementRuntime/WorldPort负责真实选址合法性；balance配表footprint与MovementObstacle逻辑radius各自保留；StructurePassGapMeters=5.6m、目标约8m，保护local+Z生产出口与矿场↔矿点通道；远程施工按最近完工己方基地，20m以内×1，20–50m连续下降，50m外×0.2，排除自身/在建基地，保留小数工量。

已实施：R1–R13选址预算、施工、电脑/副官扩张与基地角色；R14贴近建筑Box表面采矿卸货；R15矿车靠服务矿点方向安全出生；R16延迟owner初始化；R17同步终态信号连接；R18持久化开局基地/urgent状态；R19到达时间/目标关联及旧checkpoint迁移；R20保留真实Movement终态并由DCS正常采样发布；R21修正不可能满足的防御测试，行为半径未改；R22断连后不查询关闭socket；R23旧path_failed不作废新路线。

验证顺序：每个关键逻辑补丁单独新真实Match并重放旧采矿/移动/正常退局重开；GPU5FPS录像实际回看；Python声明运行时全套；独立会话自己的边界/生命周期/自然扩张探针；127Godot完整回归及失败串行复核；最后按证据更新报告/checkpoint。

当前稳定证据：R21GPU两矿交货35/2、最小逻辑边距8.525639m、坦克58.5745m；R22/R23新Match原生两腿侦察+交矿+重开rc0；R23Python1045项1044pass/1skip、rc0且全Pythonhash稳定。独立三局终态/生命周期/自然扩张已通过。R23相对用户目录造成DirAccess扫描假红，原结果保留作诊断；R24绝对目录初跑完整、失败串行部分完成，已因用户移交停止。由Cursor继续补验与优化，不再冻结其写入/构建。

共享范围已明确：Cursor执行agent/prompts/2026-10-12-ai-stutter-gpu-quality-optimization.md，涉及共用选址和电脑AI；每局核对版本，测试负载存在时不作安静性能结论。

停止条件：不继续微调已通过布局；新断言过而旧链退化立即拒绝本逻辑候选；混合hash不能晋级；连续3轮无提升换诊断方向。R15失败链已通过R16/R17定位动作生命周期，R19丢事件转向R20保留真实事实，R21独立旧失败反例经R23修复；最近局部行为失败数0，不代替全项目champion。

报告：agent/reports/closed-loop/2026-10-12-ai-building-layout.md。证据：agent/runs/20261012-ai-building-layout；原R17阶段报告保存report-through-r17.md，所有失败轮次保留。
