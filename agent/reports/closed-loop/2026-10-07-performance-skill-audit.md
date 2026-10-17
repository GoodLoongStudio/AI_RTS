# 保画质性能二次审计与常驻 skill

状态：**审计、文档/路由及独立前向评估完成。** 本轮没有修改游戏算法或画质，不宣称产生新 FPS 提升。

## 结论与顺序

优先继续减少 CPU 重复工作，而不是降低模型、阴影、迷雾或特效质量。下面除历史推出补丁外都是代码支持的待测候选；实际实施顺序按新 profile 排序。

| 顺序 | 发现/方案 | 画质/玩法影响 | 证据状态 |
|---|---|---|---|
| P0 | 纠正 PerfGrid 渲染计时单位、保留 >500ms 长帧；回归结果并入 forbidden_hits | 不改游戏，仅防误判 | 静态/API 核验；未修运行器 |
| P1 | 静态障碍空间候选、碰撞形状/trait 句柄缓存，保留精确推出 | 可以同输出，不碰空气墙/穿行规则 | 仍有全组扫描/形状查找；新收益未测 |
| P1 | 可见性观察者空间查询、批快照实际半径 | 可以同输出，不减视野与显隐频率 | 当前按目标逐个扫描 revealers |
| P1 | 玩家探索网格批写、避免重复 1→1 写入，测 COW；谨慎 dirty fog 调度 | 同网格可无损；视口依赖需证明 | 当前每个单位重扫/取数组再写回，fog ALWAYS |
| P1 | 副官路径提示一次查单位、复用有效路线/批绘几何 | 可以同输出，不减权威命令响应 | 每个受令单位全场查找 + 额外 map_get_path |
| P2 | 脚骨索引缓存、同帧骨骼更新去重、表现池、诊断日志聚合 | 保留枪口/碰撞姿态/反馈 | 站立强制骨骼更新、实例化/打印入口 |
| P2 | 同资源共享、分区域实例化；地形先同网格分块剔除 | 可保持当前细节，需要 GPU 收益证据 | 整图单个地形 surface；已有部分共享/LOD |
| P2 | 屏幕空间 LOD、阴影代理、正确粒子 AABB/overdraw 减少 | 少量可感知风险，需截图/动画批准 | GPU 候选；没有本轮性能对照 |

高价值具体入口：

- [Movement.gd](G:/AIRTS/AI_RTS/source/match/units/traits/Movement.gd:1136)：静态障碍扫描；保守界必须覆盖偏心 OBB、嵌套缩放和顺序推出后的新位置。
- [UnitVisibilityHandler.gd](G:/AIRTS/AI_RTS/source/match/handlers/UnitVisibilityHandler.gd:54)：每目标遍历 revealers；不能照搬索敌网格固定 allowance 而漏大建筑。
- [FogOfWar.gd](G:/AIRTS/AI_RTS/source/match/FogOfWar.gd:298)：已探明格栅；完整视野历史/玩家隔离不可退化，COW 分配成本待实测。
- [CommandVisualizer.gd](G:/AIRTS/AI_RTS/source/match/hud/CommandVisualizer.gd:106)：逐个全场找单位和重复求路；新命令/地图版本/空地移动域影响缓存。
- [InfantryAnimationDriver.gd](G:/AIRTS/AI_RTS/source/match/units/InfantryAnimationDriver.gd:277)：站立脚骨强制更新与索引查找；要防止优化骨骼导致碰撞/枪口过期。
- [GeneratedTerrain.gd](G:/AIRTS/AI_RTS/source/match/maps/generated/GeneratedTerrain.gd:1450)：整个地形 ArrayMesh；先同细节分块，不能把坡面直接降成折纸。

## 不能重复建设或误删

已有 TargetAcquisitionGrid、错峰索敌、异步导航烘焙/双缓冲、生成地图路径缓存、静态小地图底图、HUD overlay、部分材质缓存、GPU 粒子和资产自动 LOD 导入配置。新 Agent 要看它们是否实际生效，而不是又“添加”一遍。

小地图 fog get_image 是有上限的启动绑定探测，不能误称稳态逐帧读回。肖像已有签名复用，不能误称每帧重建。dynamic_quality=false 不代表所有地图分支画质相同，生成地图另有灯光阴影/装饰预算。

特别风险：[CannonShell.gd](G:/AIRTS/AI_RTS/source/match/units/projectiles/CannonShell.gd:88) 的 `_process` 驱动最终 ResolveImpact，不能因屏幕外或特效预算停它，否则伤害/命中时序会变。先分离并证明结算等价，再裁纯表现。

## 工具自身的遗漏

[PerfGridRunner.gd](G:/AIRTS/AI_RTS/tests/perfgrid/PerfGridRunner.gd:334) 的 render CPU/GPU 值再次除 1000；官方接口本就返回毫秒，使用旧字段会夸大“GPU 空闲”。另有 >500ms 长帧被丢弃，需保留 hitch 计数与原始间隔。[官方 RenderingServer](https://docs.godotengine.org/en/stable/classes/class_renderingserver.html#class-renderingserver-method-viewport-get-measured-render-time-gpu)

targeted/parallel runner 的 passed 未包含已计算的 forbidden_hits。skill 要求重新合并严格 rc/marker/错误/新证据门禁，不能把带 SCRIPT ERROR 的“通过”当闭环。**本轮仅记录，没有偷偷扩大范围修改工具。**

独立评估进一步发现：small-army 驱动只匹配有限错误且未检查 stop 返回值；历史 cap 阶段仍关闭 VSync，movers 不是活跃移动数，count=200 出生布局越过 208m 边界，直接 mover.move 不覆盖副官真实命令链。均已据源码核实并写入 skill，后续不能把它们当完整大部队认证。

## 交付文件

- [Skill 入口](G:/AIRTS/AI_RTS/skills/airts-performance-optimization/SKILL.md)：测量优先、不可改变的玩法/画面底线、按需阅读与交付规则。
- [CPU 方案](G:/AIRTS/AI_RTS/skills/airts-performance-optimization/references/cpu-candidates.md)：六类候选、当前代码、缓存生命周期与行为验证。
- [渲染方案](G:/AIRTS/AI_RTS/skills/airts-performance-optimization/references/render-candidates.md)：资源共享、区域实例化、地形分块、LOD/阴影/粒子及画质门禁，附官方参考。
- [测量与验收](G:/AIRTS/AI_RTS/skills/airts-performance-optimization/references/measurement.md)：同场景 A/B、尾延迟、工具陷阱、所有权启动/结束、当前 probe 限制。
- 发现入口已接入 [AGENTS.md](G:/AIRTS/AI_RTS/AGENTS.md)、[skills 目录](G:/AIRTS/AI_RTS/skills/目录.md)、[manifest](G:/AIRTS/AI_RTS/agent/manifest.json)。这是仓库级路由，不声称已给 DeepSeek/Codex 全局安装插件。
- [后续实施提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-07-performance-skill-audit.md)、[计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-07-performance-skill-audit.md)、[检查表](G:/AIRTS/AI_RTS/agent/checklists/2026-10-07-performance-skill-audit.md)。

## 验证与证据

本任务为文档/路由，不重跑游戏/全量回归/构建，没有新截图或新 FPS。复核的历史原始 JSON 时间为 2026-10-07 14:43:01：53 实体移动约 91.5 FPS 无上限，30 FPS 上限约 29.8、p95 53.972ms；该历史修复全局回归仍 needs-review。[历史闭环报告](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-07-small-army-performance.md)

| 校验 | 结果 |
|---|---|
| `python -X utf8 .../skill-creator/scripts/quick_validate.py .../airts-performance-optimization` | rc=0，Skill is valid |
| PowerShell ConvertFrom-Json manifest + conditional skill 路径 | rc=0，有效 |
| 4 个 skill Markdown 的全部本地引用 | rc=0，全部存在 |
| 编辑文档的 trailing whitespace、5 个审计源文件 hash | rc=0，无问题，hash 未变化 |
| 首次 Python 默认 GBK 读取 skill | rc=1；改为 UTF-8 模式重跑成功，未修改系统 Python/skill 编码 |
| 独立前向评估 | 通过；6 项具体执行风险已补清，未启动引擎 |

RSI round-01 的方向、探索证据和编辑说明在 [运行目录](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-performance-skill-audit/round-01/direction.md)；探索 JSON 保存审计目标 hash 和证据类别。

独立评估首轮建议：先修测量器并验证 100/200 持续移动/命令负载，再按热点选 C4 单命令 ID 映射或 C1 形状句柄缓存，不首轮同时实施索引与路径复用。材质复用新增约束已防止跨 pulse 的 alpha 互相污染。

## 风险与决策

共享工作区有大量他人修改，AGENTS/manifest/原 skills 本身此前即 untracked；保留全部现有内容，不 reset/clean/提交。Movement hash 与上轮结束一致，未更改游戏和运行器。静态候选尚未做单项速度或画质对照，不能宣称 100/200 单位已达标。

文档 candidate 已晋级，连续未提升 0 轮；产品 champion 本轮没有候选，也没有新的提升轮数。下一轮优先验证测量器，再按最大热点实施最小行为等价优化，逐步扩到 100/200 与交火/副官长时负载。
