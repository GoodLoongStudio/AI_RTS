# AI_RTS 总提示词：副官当前规则修复 + 地图生成总进度流程图

你现在处理的是 `G:/AIRTS/AI_RTS` 的**当前开发源码**。不要修改 `G:/AIRTS/打包版`，不要进入历史归档继续开发，不要移动/清空工程，不要清理 `build/adjutant_runtime`，不要执行 `git reset`、`git clean` 或批量回滚共享工作区。先读取：

- `G:/AIRTS/AI_RTS/AGENTS.md`
- `G:/AIRTS/AI_RTS/skills/airts-workspace-boundaries/SKILL.md`
- `G:/AIRTS/AI_RTS/skills/闭环验证工作法.md`
- `G:/AIRTS/AI_RTS/skills/AI_RSI自校验循环.md`
- `G:/AIRTS/AI_RTS/skills/airts-temporal-playtest/SKILL.md`
- `G:/AIRTS/AI_RTS/skills/airts-performance-optimization/SKILL.md`，按任务阅读 `references/measurement.md` 和 `references/cpu-candidates.md`
- `G:/AIRTS/AI_RTS/agent/manifest.json`
- `G:/AIRTS/AI_RTS/tools/mapgen/SKILL.md` 和其规则索引（只改进度，不改地形/材质生成规则）
- `C:/Users/Administrator/.codex/skills/game-ui-design/SKILL.md` 及其同目录 `references/patterns.md`、`references/validations.md`（本机 UI 技能，不在工程 skills 下）
- `G:/AIRTS/AI_RTS/agent/plans/2026-10-11-adjutant-map-progress-followup-plan.md`
- `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-11-adjutant-current-rules-repair.md`
- `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-11-adjutant-map-progress-prompt.md`（最新独立检查及证据局限）

先运行：

```powershell
git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel
python G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS
git -C G:/AIRTS/AI_RTS status --short
```

这是一个需要多轮迭代的任务。把下面两项放在同一个任务计划里，但按阶段分别验收；任何一项的失败都不能被另一项的 UI 或单测掩盖。每轮只改一个可证伪方向，保存 candidate/champion、目标文件哈希、DLL mtime/hash、日志、截图、视频和 rc。

本提示词基于 2026-10-11 当晚独立检查；工作区已有其他任务同时修改，开始时重读当前源码、mtime 和哈希。已存在且验证过的修复要保留，不从旧报告重复实施。地图服务可能也有活动任务：不要为 UI 改动直接结束或重启共享服务；需要新后端版本时使用独立、已确认端口的测试服务，并只清理自己创建的进程。

截图参考已保存为 `G:/AIRTS/AI_RTS/agent/runs/20261011-adjutant-map-review/map-progress-reference.png`；只参考红框区域和现有页面风格，红色框线是标注，不是要加入游戏的边框颜色。

## 一、先修 AI 副官的当前规则

### 1. 首座矿场和经济启动

当前历史真实 Match 已出现：`r10-newdll` 最后状态有 1 个指挥部、2 个车厂、1 个机场、2 架无人机、7 辆矿车；7 辆矿车均携带 400A，余额 A=150，没有 `ore_refinery`。矿车的代码类型是 `worker`。当前源码还存在两个危险口径：

- `economy_ignited()` 把任意 `worker`（矿车）存在当成经济已点火，即使没有交付目标或收入；
- 首座矿场判断同时把已有 `vehicle_factory` 当作“不是 first economy”，于是首矿可能被当成远端扩张。

请先在真实 Match 中复现，再精确修复：

1. 矿车存在、车厂存在或一条尚未完成的生产意图，都不能单独证明经济已经产生收入。
2. 首座 `ore_refinery` 必须优先使用最近可见、可采、能通过权威放置评估的矿点；不因远端扩张距离规则被跳过。
3. 分开“经济链正在建设”“已经具备可用矿场和矿车”“已经发生收入”：使用权威字段和交付事实。第二座产能及多机发展要有可持续经济/预算证据，不能由单一 `worker` 存在触发；不要拿模型输出、命令 accepted 或余额下降冒充收入。首笔交付是验收点，不应无条件锁死必要防御、首次矿场建设或无人机全灭后的最低视野恢复。
4. 远端矿场必须先满足建造网络/前哨条件；不满足时要停止重试、保留预算并记录可解释原因。
5. 第二兵营、第二车厂、额外机场和额外生产只有在经济、队列负载、战损或明确战术需求成立时开启。不能为了看起来“在发展”而先铺多座建筑。

验收要求：新 Match 中首座矿场真实实体完成，矿点库存确实减少，至少一笔资源交付/收入出现；低资金时不会反复提交同一失败建造；记录建造回执、余额、矿点库存、单位位置和退出码。

### 2. 建筑间距、出口和通行

用户反馈是“建筑造得太近会卡单位”。当前已有 `BuildRangeMeters=12`、资源搜索上限 32m 和 1.2m 邻接净隙修改，但真实通行仍未闭环，且 Godot 旧证据有：

- `OreRefinerySmokeTest=2 failures`
- `RuntimePlacementSmokeTest=1 failure`
- `StructurePlacementSmokeTest=2 failures`
- `SpawnPointRegression=3 failures`

不要直接放大一个半径或修改测试判据。请分别核对：建筑 footprint、物理碰撞、MovementObstacle/carve、导航 agent、建造网络范围、生产出口、矿场服务站位。自动选址必须对候选点检查：

- 出生点→集合点→基地出口→地图外侧/资源区→返回的真实导航可达；
- 施工前、施工中、完工后三个状态都不封死主要出口；
- 步兵、坦克、矿车都有真实出生、离开、到达、返回；
- 资源模式不被远处基地建筑的邻接候选吸回去；
- 如果远端矿场需要前哨/建造网络扩展，先实现有界前置链，或明确拒绝该点并保留经济，不得留下满载矿车堆死。

1.2m 的候选间隙不等于单位可通行：当前实现注释列 worker 碰撞半径 1.36m、导航 agent 2.8m，需重新量实际表面净空和通行路径；不能用这些不同语义的半径互相代替，也不能把所有楼间缝都当成必须走的主通道。保护真正的生产出口和采矿/基地对外通道。

真实 Match 至少录一段 5 FPS 视频，从施工前数秒开始，覆盖工地出现、施工中、完工后和单位通行；按 `skills/airts-temporal-playtest/SKILL.md` 实际回看并记录视频秒数。后台测试不得抢用户前台、移动真实鼠标或结束用户进程。

### 3. 无人机侦察和主力推进

当前规则在 512m 地图、经济条件满足时目标为 2 架无人机，已经有机场前置和第二架生产的初步证据，但以下仍未通过完整闭环：无人机损失补造、机场损失恢复、覆盖增益量化、无人机覆盖后停止抽小兵、主力推进口径核实。

请实现并验证：

1. 512m 地图本阶段目标为两架由副官负责的专职无人机，经济和侦察需求成立后再主动补充；两架必须认领不同方向，并统计相对单机增加的新视野/新区域。不要限制真人手动生产或夺回玩家接管的无人机。
2. 存活、队列、在途按实体/意图身份去重，并正确读取实际 quantity；当前计数代码按每个 item/intent 加一，需核实多数量订单和队列/accepted pending 双计数。无人机损失后节流补造；机场被毁后先恢复机场或给出明确原因，不无限重试，高防空区域要换路线/暂缓补充，不能持续送机。
3. 只有专职侦察不足或局部确认时才允许 `scoutconfirm` 抽小兵；无人机覆盖充分时不反复占用战斗单位。记录无人机侦察工时、小兵侦察工时和比例。
4. 重新确认 `source/adjutant_coordinator/graph/movement.py` 中 `RELAY_MAX_HOP_M=24` 的实际加载与真实 Match 结果。分别统计侦察、主力推进、攻击移动的命令目标距离、实际位移、到达和失效原因；不能用历史 14m 或单纯意图距离冒充新结果。

独立检查还复现了盲区反例：`_first_visible_span()` 注释说逐点检查连续覆盖，实际用端点覆盖及二分，错误地假定“圆盘并集与线段相交后，从起点到最后可见点连续单调”。构造两个单位：移动者位于 x=0、视野 4m；友军位于 x=24、视野 4m；均 `movement=true`、`pos=[x,0,0]`、`sight=4`。调用 `safe_relay_point([[0,0],[24,0]], by_name, unit='mover', origin=[0,0])`，当前返回 `[24,0]`，中间 x∈(4,20) 是盲区。应只放行第一个不可见点之前的前缀，不能跨到后方友军视野。补这个真正安全回归，用有界计算修复；不要关闭可见性约束或仅扩大 hop 上限。132 条相关 Python 测试通过仍没有覆盖这个反例，必须保留旧测试并加有区分力的新断言。

验收覆盖：model=off、model=timeout、无人机损失、机场损失、至少两个出生点/地图位置、退局重开。若使用 5 FPS 视频，必须实际解码并回看关键区间。

## 二、在地图工作台增加总进度流程图

目标界面是当前 `source/main-menu/MapGeneration.tscn` / `MapGeneration.gd` 的地图生成工作台。截图中红框的中心进度区域现在只有“G1 · 出生布局已就绪”和一行详情；右侧已显示 G2 正在生成，说明 `progress` 的旧文字与真正运行 stage 可以不同步。请把红框区域升级为**总进度流程图**，以 stage 状态决定当前节点，progress 只显示与当前阶段匹配的细节。

流程固定为：

`G1 出生布局 → G2 地形生成 → G3 资源与素材 → G4 游戏场景导出 → 引擎加载与导航验收`

### 数据和状态合同

- 唯一状态源是工作台 job 的 `status`、`stages` 和 `progress`；不要在 Godot 里另维护一套可能漂移的完成状态。
- 完整任务按五阶段显示；`target=g2` 快速预览只跑 G1/G2，其余节点显示“快速预览未运行/跳过”，不能显示完成。
- 游戏内 `skip_engine_check=true` 必须显示“跳过：游戏内生成路径”，不能显示“引擎验收完成”。
- 状态映射必须明确：`done=完成`、`running=进行中`、未开始=等待、`error=失败`、`skipped=跳过`。
- `status=done` 与 `pass=false` 要显示“检查未通过/需检查”，不能涂成绿色通过；`job.status=done` 也不等于 `map_pass=true`。引擎因上游失败未运行与快速预览主动跳过要有不同原因。
- 失败阶段后续阶段不能伪装完成；重试时旧的当前阶段、错误和进度必须被新 job/stage 覆盖。保留历史记录，但不得使用旧图/旧状态充当当前进度。
- 只显示后端真实提供的 `attempt/limit`、耗时、阶段详情、重试原因；没有真实百分比时显示“第 N/5 阶段”，不要猜一个平滑百分比。
- 自动布局轮换会清除上游 stages 并重做 G1/G2/G3，要显示“改试新布局/第 N 次尝试”，允许真实状态回退，不能为了进度条单调保留旧布局完成状态。

### UI 结构和视觉要求

在中心 `ProgressBanner` 中实现可读的水平流程图（窄窗口可换成两行或竖排）：

- 每个阶段是带编号、名称、状态文字的节点，节点之间有方向连接线；当前节点有明显边框/发光，完成节点有完成标记。
- 颜色保持截图的暗色科幻风格：完成绿色、当前青色、等待/提示琥珀、失败红色、跳过灰色；每种状态同时显示文字、编号或图标，不能只依赖颜色。
- 流程图下面显示一行总状态：例如“完整流水线 · 2/5 阶段完成 · G3 资源与素材进行中”，以及耗时/候选轮次；当任务失败，显示失败阶段和可重试原因。
- 完成或失败后保留这一任务的全流程结果；不要像当前实现一样非 running 就隐藏整个进度区。任务提交/连接阶段、无任务、进度暂未返回也要有真实等待状态。
- 右侧“地图检查”列表和中心流程图必须调用相同的 `STAGE_ORDER`、`STAGE_TEXT` 和 stage 数据；不要维护两套状态字符串。
- 不遮挡地图预览、图例、历史卡片和左右栏；至少检查当前截图比例以及 1280×720、1920×1080、窄窗口。文字最小保持可读，长错误用省略号并可通过悬停/详情查看。
- 生成时可以保留旧预览，但必须标明“上一张地图预览/当前新地图尚未完成”；切换历史任务时，流程、右侧检查、预览和标题都绑定选中 job，活动生成任务另用简短标记显示，不混用两张地图的数据。
- 流程图是上下文关键 UI，动画只用于当前节点/连接线的轻微状态变化，不能持续高频闪烁或增加生成任务压力。

### 后端/进度必要修补

先确认 `tools/mapgen/rtsmap/workbench/pipeline.py` 和 `server.py` 已把每次阶段开始、阶段完成、阶段失败、跳过、布局重试写入 job。若中心 UI 无法区分“阶段完成后正在渲染复核图”和“阶段仍在运行”，补充明确的后端字段或阶段细节；不要在 UI 层靠延时猜测。

沿用当前有限轮询频率和 HTTP token 防旧响应机制，断连提示“暂时无法获取进度”并有限重连，不能把网络超时直接写成生成服务任务失败。不要为流程图每帧读取文件/发 HTTP、重建所有控件或加载地图纹理。新增导航/选址查询只在事件或受预算的决策阶段触发，不做每单位×全地图扫描；保持已有线程职责，SceneTree/导航/GPU 对象继续在现有权威线程使用。性能比较看帧时间、模拟秒/墙钟秒、命令延迟及队列积压，不能只报告空局 FPS。

## 测试和交付

编辑后按顺序执行：

1. GDScript 解析/场景加载；C# 若改动则 `dotnet build OpenRTS.sln -c Debug --no-restore --nologo`。
2. 副官相关 Python 单测和地图工具相关测试；失败先分类，禁止为了绿色放宽断言。
3. 启动真正 `Match` 新进程验证副官经济、建筑、无人机和移动链；启动地图工作台生成一次 G2 预览和一次完整 G1→G4→引擎任务，确认进度状态与任务状态一致。
4. 生成可见截图并实际打开查看流程图；动态副官链录 5 FPS 视频并实际回看。
5. 检查新鲜产物 mtime、实际加载的 DLL、Godot/runner 退出码、实例清理和进程树。`r10-newdll` 是 Python runner 的 `3221225477`（0xC0000005），同轮游戏驱动记 `game_rc=0`，不要直接断言 Godot 崩溃；核对是否自然崩溃、原生依赖错误或测试终止，以及失败发生时间。没有归因不能当正常完成，不能只报告中途成功或把大量 DCS timeout 忽略。

UI 测试覆盖一轮真实完整生成和 G2 预览，另用隔离可控响应覆盖长阶段、done/pass=false、失败、skip_engine_check、重试、自动布局回退、切历史、返回再进入、迟到 HTTP 响应和服务断连；不要破坏活动服务制造异常。地图后端复用 `tools/mapgen/tests/test_pipeline.py`、`test_g2_workbench.py` 等已有测试，必要新断言验证状态合同。分别记录规则 model=off 与 timeout 档；若正常小模型不能实测就写未验证，不能说“小模型已接好”。

报告至少包含：

- 改动文件和工作树/DLL hash；
- 首座矿场完成、首笔交付、余额/矿点库存、单位通行、无人机覆盖和补造的真实数值；
- 流程图截图路径和各状态（完成/进行中/等待/失败/跳过）截图；
- 每条测试命令、rc、expected marker、forbidden output、崩溃/超时；
- 5 FPS 视频路径、实际回看时间段、缺帧/遮挡/未验证项；
- candidate/champion 决策，历史失败的归因，下一轮仍需解决的问题。

在所有关键门禁通过前，最终状态必须写 `needs-review` 或 `blocked`，不得写“全部完成”。
