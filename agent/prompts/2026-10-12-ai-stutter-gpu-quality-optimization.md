# 交给实施 AI：消除严重卡顿，并保画质优化 GPU 渲染

用户目标：游戏流畅、AI 正常工作、画面仍然舒服。请实际完成定位、实现和逐轮验证，不要只回复建议，也不要每做一小步就让我选择 A/B/C。已有插件和 MCP 是可用工具，由工程证据决定方案。不要让插件能力反过来决定游戏架构。

常驻计划：[实施计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-12-ai-stutter-gpu-quality-optimization.md)。开始和每轮结束都重读并更新它。
实测入口：[2026-10-12 单人对局诊断](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-12-singleplayer-live-performance.md)。以下数据是交接基线，不是你当前源码的认证；先检查是否已有其他 AI 修复。

## 1. 范围与优先级

开发根必须是 `G:/AIRTS/AI_RTS`。先读 `AGENTS.md`、`skills/airts-workspace-boundaries/SKILL.md`、`agent/manifest.json`、`skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md`，再用 `skills/airts-performance-optimization/SKILL.md` 及 measurement、cpu-candidates、render-candidates 参考页。涉及动态画面时读取 `skills/airts-temporal-playtest/SKILL.md`。

先运行 Git 根、status 和实际目标的 `tools/check_workspace_target.py --mode develop --target <绝对路径>`，路径检查必须 rc=0。核验文件已有 diff、mtime、测试实例和 C# DLL 身份，保护共享工作区；不覆盖其他 AI 改动、不 reset/clean、不更新打包成品、不清理模型运行依赖。

按以下顺序实施，两条产品线都要交付：

1. P0：消除规则 AI 的同步长任务及其他可复现的游戏内严重长帧。这是影响体验的已测问题。
2. P1：检查副官 runner / 本地模型的 CPU、GPU 竞争，避免后台任务挤占游戏资源；副官必须继续正常指挥。
3. P2：拆分 GPU 渲染成本，实施有实测收益的同画面优化。不能只完成 CPU 后跳过渲染，也不能先改画质来掩盖长帧。

保留移动、碰撞、避障、建造、出生、采矿、生产、攻击、视野、迷雾和网络权威合同。保持单位/建筑尺寸、速度、射程、物理频率、模拟速度与实际工作量。远离镜头的单位仍然要完整模拟。

## 2. 已测事实与不可越过的证据边界

2026-10-12 正常 Play 单人房：一名真人、一名中等规则 AI，副官正常自动启动，PlainAndSimple 512×512，Godot 4.7.1 .NET / Forward+ Vulkan / RTX 3080 Ti。

| 指标 | 已测结果 | 正确解读 |
|---|---|---|
| r02 前两段平均 FPS | 325.1 / 322.1 | 小规模，实体 8→19 / 20→33；不是大部队成绩 |
| 主视口 GPU 均值 | 1.87 / 1.83ms | 有持续渲染开销，尚未确认最贵 pass |
| 主视口 CPU 渲染提交均值 | 0.48 / 0.55ms | 不是全部主线程时间 |
| r03 同帧长任务 | 帧 648.887ms / arbitration 638.681ms | 仲裁桶包含同步 provision 执行链 |
| 另外两次同帧关联 | 315.306 / 313.505ms；140.321 / 138.333ms | 重复出现，不能只看平均 FPS |
| 其他长帧 | 142.602ms 等 | 尚未归因，继续查，不能忽略 |
| runner 峰值 CPU | 约 12 核同时忙 | 内部导入、线程池、计算/调用占比未测 |
| r03 整卡 GPU | 平均 94.3%，78–99% | 同时有模型和其他程序，不能全部算给游戏 |
| 实际地形 | 257×257 顶点，131072 三角形 | 512m 地图不等于 513×513 顶点 |

r03 有其他测试/任务竞争且启动激活异常，229 FPS 不能和 r02 作优化 A/B。r02 later 338 FPS 有世界暂停迹象，已排除。当前小规模导航监控约 0.011ms，不代表 300/1000 单位的避障已经解决。

## 3. 先把测量工具校准，再建当前基线

- 复用 `tools/dev/singleplayer_live_perf.py`、既有 Instance/MatchGroup、MCP/DCS 和统计器；先验证工具资格。该脚本最后补充的 QueryPerfStats 与前台拒绝分支仅通过 Python 编译，尚未完整 Godot 运行验证，不能直接称可靠。
- `tests/perfgrid/PerfGridRunner.gd` 当前有 GPU/CPU 原生毫秒再次 `/1000` 和丢弃 `dt_ms > 500` 的问题。若使用它，先作为独立诊断补丁修正并验证；所有原始长帧都保留。全零 GPU 数据写 unavailable。
- `Engine.get_physics_frames()` 会在世界暂停时增长，不能代表模拟秒/墙钟秒。记录真实 Match 模拟时钟、`tree.paused`、实际位移/伤害/资源产出和 physics tick；计时 bookend 不能包含两次 tick 之间的等待。
- inclusive 桶和其子项不能相加；主线程、CPU 提交、GPU 工作可能重叠。记录墙钟帧、线程、调用次数、max/p95 和长帧关联，现有累计均值不足以定位尖峰。
- 固定地图/种子、镜头、分辨率、实际画质、相同动作与实体负载。每个基线/候选至少重复三次或 A-B-A，记录波动和最差尾延迟。冷启动与预热稳态分开；先做 A/A 看测量噪声。
- 容量测量和生产体验分开，记录且恢复原 FPS cap/VSync；不落盘修改玩家偏好。动态画质调节不能暗中替候选改变质量。
- 不在性能窗口中录制或同步截图读回；截图/录像另开验证时段。所有采样中的读回、加载、推理与前台变化仍保留原始事件，不删掉后得到漂亮数字。
- 不与回归、导入、大型构建或另一个性能实例同时比较。记录其他进程负载，不结束用户/其他 AI 的工作；无法保持条件的样本标为受污染并补测。

后台测试不弹 CMD、不抢前台、不置顶、不移动真实鼠标、不注入系统键鼠、不要求用户停止聊天。使用隐藏辅助进程、非激活渲染窗口和引擎内接口；正常 GPU 刷新不能靠最小化。启动/切场景核验实际窗口和 foreground；可靠隔离未通过先修工具。不能循环拉窗口回前台。动态端口、实例所有权、租约、watchdog、finally 清理，只清理本轮进程，并验证登记和子进程消失。

## 4. P0：AI 长帧要拆内部执行链

先读并实测以下入口，而不是按函数名猜热点：

- `source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd`：`_try_fulfilling_resource_requests_according_to_priorities` 的 `while progressed` 和同步 `_provision`。
- 同目录 EconomyController / DefenseController 的建造决策链。
- `source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs`：`FindAutoSpot` / `FindAutoSpotInstrumented`，候选生成与 `_service.Evaluate`。
- `source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs`：`EvaluateDetailed` 内实体、资源、地形、导航、占用/形状检查。

优先扩展已有 `AiPerfStats.gd`、`QueryPerfCounters.cs` 和 `WorldQueryRuntime.GetQueryPerfStats()`；环境开关 `AIRTS_AI_PERF_STATS=1`。把仲裁、资源查询/快照、选址候选、精确评估、提交/实例化分别计时，标明包含关系和每次最大值，并与同帧 hitch 关联。测探针本身开销，避免日志洪水和逐帧大 JSON。

**仅把外层改成每帧一个请求、call_deferred 或先 await 一帧无效：单个请求内部仍可能阻塞约 600ms。** 根据实测最贵子阶段，把它做成可续状态机，真正拆开内层扫描/求解；一次昂贵原子操作若已超预算，继续拆它。初始可评估所有 AI 合计每帧约 1–2ms 的工作预算，按硬件、目标帧率和请求延迟校准，不能每个 AI 各占同样预算叠加，也不能靠少思考/不行动达标。

必须保留以下合同：

1. 原优先级和合法选址语义、可负担请求扫描、公平性、请求生命周期；不重复执行、不丢请求、不让低优先级永久饥饿。
2. `Pending/BudgetExhausted` 与 `NoValidSite` 区分；跨帧保存搜索进度和原候选次序，不能预算耗尽就报无地可建，也不能只找到部分候选就改变原最优选择规则。
3. 先测同一任务内数据复用、廉价拒绝、保守空间候选。缓存要有真实的占用/地形/所有权/形状版本，同一帧新建或拆除也必须失效；只有 physics frame 标记不足。
4. 快照制作、缓存维护、结果验证成本同样进预算。区分静态占用版本与动态状态，避免每 tick 全局失效导致搜索无限重启；设任务 deadline、取消和有界重试，过期结果不能强行提交。
5. 最终在主线程原子重新检查余额/预留、请求仍有效、当前建筑状态和占用/地形/导航合同，提交一次。消亡、换局、撤销请求、同时建造、余额变化和线程晚回调都要安全。
6. 共享选址 API 同时服务电脑 AI、副官和玩家。保留现有同步调用接口语义，新增异步适配要逐调用方核验，不让其他入口收到未处理的 pending 或空结果。

多线程只用于经证实值得外移的纯数据计算。主线程捕获有版本的稳定数据，工作线程只读数据求解，返回带版本结果；主线程验证和提交。禁止随意在工作线程访问 SceneTree/Node、改变换/骨骼、执行 Godot 导航/渲染查询或直接造建筑。线程数量有总预算、队列有上限、任务可取消；测拷贝/调度/锁/等待与 GC，不能用主线程等待 future 抵消并行收益。

## 5. P1：副官与模型资源竞争

同时记录 runner 冷启动、导入/数值线程池、实际推理开始结束、模型服务、游戏帧和 GPU 队列时间线。整卡占用不能代替单进程归因。
优先复用已有服务/初始化、减少重复观测、异步非阻塞通信，再按实测给本轮 runner 的数值线程池和纯计算合理预算；不要全局限死其他应用，也不要堆更多线程造成争抢。
副官协议、回执、编组/监控、实际命令完成必须端到端通过。关闭副官/模型仅可作可逆归因实验，不能作为最终成绩；测等待、响应、错误恢复和队列积压，不允许推理任务无限堆积。

## 6. P2：GPU 要实测 pass，先做同画面优化

取得当前后端有效的主视口及 fog/minimap 子视口 CPU/GPU 时间、可见物体、draw calls、primitives，能用现有 profiler/render profile/RenderDoc 再查阴影、地形、材质、透明粒子等 pass。工具不可用的字段如实写 unavailable；不以安装工具替代执行，也不把整卡 99% 当某 pass 证据。

候选按当前实测收益排序，每轮一个；以下都是候选，不是已证实瓶颈，也不是全部强制实施：

| 候选 | 先做的方向 | 必须保护 |
|---|---|---|
| 地形空间分块 | 同顶点/三角形、全局 UV/法线/纹理掩码，测块尺寸与 draw call 代价 | 512m 尺度、河道/桥/崖壁、接缝、阴影；不改权威地形/导航/碰撞 |
| 材质/网格共享 | 查实际 identity、已有 team cache、Forward+ 自动实例化和导入 LOD 是否生效 | 阵营色、炮塔方向、选中、蒙皮动画和逐玩家显隐 |
| 静态装饰批次 | 同 mesh/material 按空间块的 MultiMesh，测上传和剔除收益 | 不合成全图一个批次，不把骨骼战斗单位强行合并 |
| 阴影 | 查最贵投影；低复杂度且轮廓贴合的 shadow mesh/proxy | 接地感、近镜头轮廓、移动动态阴影、屏外投影贡献，不双重投影 |
| 材质/透明效果 | 经 pass 证明后减少重复取样、空白面/重复 overdraw，共享资源与池化 | 水体/法线/遮罩/透明排序、爆炸和采矿反馈，权威命中完整执行 |
| 视口/表现调度 | 只跳过真正未变的表现工作，维护完整依赖 | 首帧、显隐时序、迷雾历史、换局，不重现黑图 |

优先结果相同的优化。仅在其收益不足且确有 GPU 热点时，允许对远处难辨细节做小幅 LOD/烟雾尾部优化，先记录可感知差异，再过画质门禁。禁止默认降分辨率、关闭抗锯齿/全部阴影/迷雾、删特效、改亮度掩盖画面损失；近处轮廓和交互反馈必须保留。正交镜头 LOD 按投影像素验证，不靠世界距离一刀切。

## 7. 每个候选都要截图并真的打开看

每个产品候选保存 champion-before 和 candidate-after 的新鲜原分辨率截图；不等最后一张。使用已核实属于本轮实例的游戏视口捕获，不录用户桌面；在 `frame_post_draw` 后取图，截取不进入性能采样窗口。

- A/B 固定分辨率、镜头投影/变换/zoom、种子、地形、灯光/质量最终参数、实体数量/位置/HP/选中、阵营、迷雾状态及特效生命周期。动态内容用固定回放和相同模拟时间对齐；无法对齐的截图不能独自证明同画面。
- 每张附元数据：run_id、源码/DLL hash、UTC、地图/seed、相机、质量、实体/可见数、动作/相位。原图不可覆盖，近景细节加裁切与联系表。
- 实际打开每组 before/after，逐项写观察结果和通过/拒绝原因。生成文件、自动 diff 或“looks good”均不算审阅；图像差分只能辅助判断。
- 至少覆盖默认约 80m、最近/最远 zoom；河道/水纹/桥/崖壁/地形块边界；主基地/矿场和各主要单位的阴影/阵营色/选圈；雾边界/小地图/HUD；密集爆炸、采矿和连续右键反馈。
- 渲染候选至少打开固定总览和受影响细节图；阶段晋级覆盖完整画质矩阵。出现裂缝、纹理错位、阴影跳变、单位消失、明显糊化、河面异常就拒绝，不能解释成“换性能值得”。
- LOD/粒子/阴影切换另用 5–15 FPS 短视频或连续帧，实际回看并关联动作/状态；静态截图不能证明运动不闪烁。录制与实时性能 A/B 分开，离线 movie capture 不是实时 FPS。

## 8. 改一项就复验，再决定晋级

固定循环：保存 champion 和假设 -> 精确小补丁 -> 解析/编译 -> 新进程无头真实 Match -> 受影响正反断言 + 一条旧玩法链 -> 同条件有渲染性能 A/B -> 新截图打开审阅 -> 相关回归 -> promote/reject。

无头必须产生真实单位/建筑、命令、位移/到达、攻击伤害或资源产出，记录真实模拟/墙钟比例，正常退局重开和清理。空场景或纯函数绿不能替代。无头不能认证 GPU。S1 失败不能叠下一项优化；只精确撤销自己的补丁，保留他人工作。

AI/选址按范围至少读取并执行配置中的 `rule-ai-aggression`、`rule-ai-battlegroup`、`rule-ai-defense`、`rule-ai-economy-query`、`rule-ai-expansion`、`rule-ai-intelligence`、`rule-ai-offense-logistics`、`runtime-placement`、`structure-placement`、`same-frame-overlap-placement`、`blueprint-switch`，并以 `worker-gather` 等旧链路复验。地形/表现按影响追加 `terrain-ground-collision`、`unit-grounding`、`fog-of-war-sight-range` 等，套件 ID 以当前 `config/full_regression_suite.json` 为准。

测试通过必须同时有 rc=0、expected marker、forbidden_hits 为空、无超时/崩溃、新鲜产物和 cleanup_ok。既有错误用同基线独立复现归因，不放宽断言/过滤日志。最终关键改动独立复核并执行全量回归；已有红项如实列出，不称全项目全绿。

## 9. 目标与交付

详细门禁和验收矩阵见实施计划。必须减少长帧而不是把开销挪到下一帧、加载或后台队列。平均 FPS 提升不能掩盖 p95/p99、命令延迟、AI 发育/攻击变差。GPU 收益必须超过相同条件重复测量噪声，画质门禁不能以 FPS 抵扣。没有证据不承诺回到 400 FPS 或 1000 单位稳 30 FPS。

在 `agent/runs/<run-id>/round-XX/` 保存 hypothesis/direction、patch、原始计时/日志、`headless_match.json`、before/after PNG、visual-review、verification；维护 checklist/champion。连续三轮不晋级换热点或设计方向，禁止无限调小参数。普通实现选择自行解决，真实不可解的阻碍说明缺什么证据/条件。

最终写 `agent/reports/closed-loop/<日期>-ai-stutter-gpu-quality-implementation.md`：改动范围、每轮接受/拒绝、同场景前后数值、严重卡顿归因及是否消除、GPU 收益/噪声、截图链接和实际观察、视频区间、测试命令/rc、独立复核、未验证项、环境竞争、清理结果。更新计划状态。不能用“已优化”替代这些证据，不能把只写方案或关闭功能称交付。
