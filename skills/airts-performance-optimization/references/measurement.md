# 测量、验收与工具防误判

## 固定合同

优化前和用户/计划明确目标硬件、目标部队规模、地图、镜头、质量档及帧预算。当前默认锁 30 FPS，预算约 33.33ms；用户要求 60 FPS 时是约 16.67ms，不用旧上限擅自替用户定目标。

先锁画质/相机/模拟频率，记录最终运行值，不只记 config。性能 probe 可在自己的进程临时关闭 VSync/解锁 FPS，以区分容量；再回到正常生产上限检查卡顿。不落盘改变玩家偏好，确认 governor 或大型地图分支没有自动改变质量/物理参数。

“生产配置”检查要恢复并记录原 VSync，不能只恢复 max_fps。当前 small-army 的 production_30fps_cap 仍关闭 VSync；历史数字只是该 cap 条件，不证明普通玩家 VSync 下的帧节奏。小平图/生成图也可能采用不同原有 physics tick（目前大型生成图分支为 20Hz），保持各自合同，不用改成统一低频获得收益。

负载按目标扩展：先复现 50 左右小部队，再 100/200，500 或更大由需求/硬件预算决定。每档至少覆盖闲置、群体移动/拥挤、持续交火、采矿/产兵/建造；加副官持续命令与退局重开测长时状态。小平地图和实际生成地图分别测。逐步增加，早停严重超时/错误，不能用无限等待“完成验证”。

## 需要保留的数据

| 数据 | 判断用途 |
|---|---|
| 引擎/后端/CPU/GPU、窗口/分辨率、相机投影/变换、VSync/FPS cap、physics tick/time scale、画质参数、地图 seed | 确认同场景与同画质 |
| 提交/工作树目标文件 hash、C# DLL hash、run_id、开始/结束时间 | 识别共享工作区、重编译及旧证据污染 |
| 总实体/活跃 mover/静态障碍、可见数量、开火/命中/产出次数 | 防内容变少导致虚高 FPS |
| 墙钟 render frame p50/p95/p99、平均/1% low FPS、最长帧、>预算与>100ms/500ms 计数 | 区分吞吐和卡顿，不删长帧 |
| 各热点调用数、inclusive/exclusive 时间、索引维护/缓存失效、分配/GC/内存/节点峰值 | 避免只看被优化函数或转移成本 |
| 主视口与 fog/minimap 子视口 CPU/GPU 渲染耗时、draw calls/triangles | 识别渲染、透明填充与额外 pass |
| 命令/索敌/显隐/路径失败发现延迟、到达/卡住/非法穿行、网络信息隔离 | 不用降低响应换 FPS |

对于可见数量、GPU time 等工具无法测的字段标 `unavailable`，不能填 0 冒充没有成本。

采样前预热至内容/单位数稳定，并用相同秒数样本比较；至少重复 3 次或 A-B-A，记录波动/中位数和最差 p95，不拼接不同场景的最优数字。首次资源/管线编译和加载另列，不能把它们和稳态混作一个均值。不得并行跑回归、导入、大型构建或多个性能进程。

截图使用 frame_post_draw 之后的新图，需实际打开；A/B 的单位、雾、阴影、UI、相机、特效相位一致。可放在采样窗口外；若采样内 readback 导致 stall，标注事件并同时保留包含它的原始数据与单独解释，不直接删除所有长帧。截图不能证明动画、特效时序或玩法正确，必要时多帧/视频/轨迹。

## 已有工具及限制（2026-10-07）

### 正常可用的复现入口

`tools/dev/small_army_performance.py` 使用 `tools/dev/match_instance.py::Instance`、动态端口和 finally.stop：

```powershell
$env:AIRTS_GODOT = 'G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
$run = Join-Path 'agent/runs' ('perf-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
python tools/dev/small_army_performance.py --out (Join-Path $run 'small-army')
python tools/dev/small_army_performance.py --equivalence --out (Join-Path $run 'push-equivalence')
```

引擎路径按本机实际位置调整。脚本默认 46 个新增混合单位，最终还有 5 个车厂和 2 个开局实体；不能把 `--count 100` 说成全场正好 100。提高 count 前检查镜头覆盖/出生区域/脚本负载是否成立。

当前夹具 `--count 200` 最后一排初始 z=209，已超过 PlainAndSimple 声明的 208m，镜头也不是大部队覆盖设计；不能直接把参数改大当合格 200-unit 验证。先调整独立夹具的出生网格/地图/镜头，保留与产品相同的出生规则，并证明单位没有越界、聚集或少生成。

JSON 的 movers 只是 Movement trait 数量，不是实际移动中的数量；moving 阶段只下过一次 move，单位到达后测到的可能已是低负载。另记录在途/实际位移/到达/卡住数和轨迹；持续移动负载需固定可重复路线和命令节拍，不能用删单位/完成移动伪造收益。nav_ms 只是阶段末一次 monitor 值，不是整个阶段 RVO 的独立耗时。

该夹具不经过副官协议/回执/路线表现。副官压力应使用固定本地命令序列，经真实命令入口和 `source="adjutant"` 的广播/表现链路回放，记录接收/受理/回执/路线显示/完成时间及 command_id。不额外调用收费模型；只循环 mover.move() 或伪造展示信号不能替代端到端命令负载。

该探针检查 rc/标记/错误、新 JSON/PNG 和有效阶段最低平均 27 FPS。**这不是 p95/p99/500 单位的性能认证**，需按任务补指标与门禁。中间断开 velocity callback 只是 A-B-A 热点隔离，既没保留玩法也不能作为验收成绩，最终必须恢复。没有 p99 的历史 JSON 不得猜一个 p99。

探针自身也有门禁缺口：当前错误 regex 只匹配 SCRIPT ERROR、Parse Error、行首 ERROR，不覆盖 full_regression_suite 的全部禁用输出；finally 调用 Instance.stop() 却没有检查其布尔结果。严格验收要补 full forbidden 检查，保留 cleanup_ok 并核验本轮拥有的进程树/登记已消失，不能以“有 finally”证明没有僵尸实例。本 skill 只记录，未修驱动。

其它 Match 启动沿用 Instance/MatchGroup 的所有权、端口、租约、限定超时及 finally 清理；用实际可用的 MCP 时也先验证实例归属。绝不按进程名/占端口杀别人的 Godot，不开多个“僵尸房”。

### 需要先纠正的测量器

`tests/perfgrid/PerfGridRunner.gd` 有 100/200/400 和移动/交火夹具，但审计发现：

- `_sample_loop` 把 `viewport_get_measured_render_time_cpu/gpu` 又 `/1000`；官方 API 已返回 **ms**。使用这些字段前先修单位并验证实际后端支持，旧 JSON 的 render_*_ms 可能小 1000 倍，不能以它证明 GPU 空闲。[RenderingServer 计时](https://docs.godotengine.org/en/stable/classes/class_renderingserver.html#class-renderingserver-method-viewport-get-measured-render-time-gpu)
- `_process` 丢弃 `dt_ms > 500`，会隐瞒最严重卡顿；应保留原始长帧和 hitch 计数，不只计算被过滤后的漂亮分位数。
- 只测主 viewport 不等于所有 fog/minimap pass；CPU render 不包含全部脚本和模拟成本。
- `_freeze_presentation` 设定测试质量参数，不证明它等同于生产实际画质；明确区分标准化工具负载与真实玩家负载。

以上是静态/API 口径核验，**本 skill 任务没有修改运行器**。先单独修测量器、校验一小段样本，再执行大规模比较。

`tests/performance/PlayerVsAiPerformanceBaseline.gd` 是 headless/fixed-FPS 逻辑吞吐证据，不是可见 GPU 画质性能。内置 process/physics/navigation monitor 可能含重叠或异步时间，不能直接当互斥阶段相加。包 `_physics_process` 的 G4PERF 也不涵盖晚到的 velocity_computed 回调；热点要在实际路径计时。

### 测试真假绿

当前 `tools/run_targeted_godot_tests.py` 和 `tools/run_parallel_suites.py` 的 passed 只检查 marker+rc，另存 forbidden_hits 未并入 passed。使用结果时必须按 **rc=0 + expected_marker + forbidden_hits为空 + 无超时/崩溃 + 当前产物** 独立判定。不要改标记/断言消除失败。历史全量失败见小部队报告，不能笼统称“全部无关”。

## 候选比较与停止

先写可证伪假设，例如“保持同一 200-unit 显隐输出，减少每拍候选检查，同时 p95 降低”，记录允许运算误差和响应预算。诊断禁用某模块只能帮助归因，不进入正式评分。

同输出候选以新旧算法/暴力参照逐步比较：位置、方向、候选/可见集合、碰撞/净空/到达、伤害/射程、产出/采矿等按实际影响选择。非交换的循环不能随意换顺序；索引不得漏碰撞/可见候选，cache 不得有过期权威数据。

产品改动遵循仓库的编译/解析、相关及全量回归、真实 Match、独立复核；全量失败用旧版/独立副本对照，不能把错误当噪声忽略。文档-only 无需重跑引擎，交付说明跳过运行时测试。

接受候选须收益超过同场景重复测试噪声、尾延迟没有不可接受回退、画质/行为/内存/响应没有越界。不能用主场景平均值提升掩盖小规模倒亏或长时泄漏。收益不明两轮换诊断角度，连续三轮不晋级按 RSI 阶段饱和处理；避免无限调参。

每个 champion 记录准确的负载/硬件/质量范围；没测过的大部队/地图/网络场景仍标未验证。把报告与数字附入长期证据索引，不复制整个日志到 skill。

## 查询官方原理时

查本机引擎实际版本/API 支持，再查官方文档，不能按插件说明或老版本教程猜。[导航优化](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_optimizing_performance.html)解释重复 path query、几何解析、bake 和地图同步分别有成本；本项目已有异步 bake/双缓冲/collider 源，先测剩余部分。
