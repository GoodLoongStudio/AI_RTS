# 战略层保持与 Laya 执行纪律

日期：2026-10-12。状态：模型战略没有修好。2026-10-13 第二局用规则主线降级，证明了采纳一次再维持（`plan_version` 不变）。这不是模型计划。
执行入口：[提示词](../prompts/2026-10-12-cursor-strategic-layer-laya-command-discipline.md)。
纳入同一条任务，不另开工作线：[性能计划](2026-10-12-ai-stutter-gpu-quality-optimization.md)、[接管提示词](../prompts/2026-10-12-cursor-takeover-building-adjutant-and-performance.md)。
路径检查：`check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS/source/adjutant_coordinator` 与本计划路径均为 allow。

## 目标

战略层看整盘、可以慢，但判断要稳。计划提交后由 Laya/规则执行层按编组持续做完，不再让部队无目标折返。探索用少量无人机，不把战斗机（代码 id `helicopter`）当侦察产量。性能 P0/P1/P2、建筑布局和采矿合同继续有效。没有真实对局的计划稳定性证据之前，不宣称战略层已修好。

## 本机实际调用链（源码，尚未用新对局证明）

```text
Godot 权威观测
  → runner 主循环（默认协调 0.25s，完整视图默认 1.0s，扫描默认 0.1s）
  → graph classify_route
       玩家控制事件 → player interrupt
       紧急事件且过了 emergency 间隔 → emergency tactical
       is_strategy_due 且未冷却 → strategic
       否则有事件且过了 tactics 间隔 → tactical
       否则 wait
  → 无论路由，node_classify 每轮都跑规则/行为树 baseline
  → strategic：node_strategic_agent 在图调用线程上直接 propose_plan
       PydanticAIStrategyAgent._run_text 把推理丢进共享线程池，
       然后 future.result(timeout) 等结果。超时后不 cancel，在途槽仍占着。
       战术侧已有 tactics_scheduler；战略侧没有同等 poll 调度。
  → 采纳后整份替换 active_plan，plan_version 写成 plan_id:vN，
       plan_adopt_generation 加一
  → tactical：四列 TaskPatch，默认 AIRTS_S1_BACKEND=laya 的选择链
       元数据（plan_version / task_id / 代际）由宿主补齐
  → 仲裁、移动在途守卫、小队编组
  → 权威命令与回执
```

间隔事实，不能当成“思考要 30 秒”：

| 位置 | 当前值 | 含义 |
|---|---|---|
| `agent_runner.py --strategy-interval` | 默认 1800 tick | 按 60Hz 约 30s，按大图 20Hz 约 90s |
| `runtime.py` / `GraphConfig` | 默认 3600 tick | runner 会覆盖成上面的参数 |
| `is_strategy_due` | 无计划、间隔到、或重大事件且计划已过期 | 普通重大事件在计划未过期时不会提前复核 |
| 战略提示词 | 每次 `plan_version` 必须更大，tasks 不得为空，且必须同时覆盖经济/军事生产/侦察/防守 | 语义相同的复核也会被要求换成新版本 |
| 战术调度 | `tactics_scheduler` 异步 poll | 战略等待不走这条 |
| 线程池 | 类级共享，最多 2 个 worker | 两个角色各有在途标记，不等于 GPU 隔离 |

## 和用户截图对齐的源码线索

界面“战斗机”就是 `helicopter`（`Ra3Sidebar.gd` 飞机页：无人机 200，战斗机 900）。`PRODUCT_LADDER` 写明机场只产 `helicopter`，不产 `drone`。`recon_produce_intent` 只在专职侦察低于目标时补 `drone`：小图目标 1，开局已经有 1 架就不再补；大图且经济已点火才到 2。作战单位在没有可见敌人时走 `attack_move` 前压。战略提示词把侦察写成“少量机动单位”，没有写成无人机。

这能解释“阶段在摸索，侧栏战斗机在排队”。它还不是对局证明：没有本轮的 `strategy_calls`、计划版本和每小队目标变更记录。

## 假设（一次只证一个）

1. **H1 侦察产量**：无敌情时机场阶梯把名额给了战斗机，专职侦察配额已被开局无人机占满，所以探索没有继续造无人机。先用一局开局记录 produce 的 scene、单位类型和随后的 scout/attack_move。通过之后才改产量，不和调度混在同一轮。
2. **H2 战略阻塞**：`node_strategic_agent` 的 `future.result` 会让这一轮图调用停住；Laya/规则是否同时停住，要用慢推理对照（思考期间采矿、移动、生产还有没有进度）。通过之后才把战略收成和战术一样的有界 submit/poll。不先改 1800 这个数字。
3. **H3 计划被换掉**：提示词强制更大的 `plan_version`，采纳器整份替换计划并增加代际。要统计一次复核是不是把仍有效的经济/防守任务也作废。通过之后才允许“维持现计划”且版本不递增。
4. **H4 执行折返**：相同 task、编组和目标是否仍能绕过移动守卫，变成短时间重复改道。H1–H3 没有各自的对局之前不动这条。

## 验收阶段

- A：全局摘要能解释当前大目标，未知敌情保持 unknown。
- B：稳定任务交给 Laya 后，编组持续推进；普通复核可以维持原计划。
- C：遇敌、路径失败、玩家接管、模型超时仍正确，且副官开着的性能不回退。

程序检查目标约 1 秒，只读缓存和增量事件。战略模型先对照 30 秒现状、15 秒解耦候选、10 秒；10 秒稳定后再试 5–10 秒。暂停不补发错过的请求。重大事件去抖后提前复核，基地受袭仍走现有紧急链，不等模型。

## 明确不做

- 不重写第二套指挥中心、地图库或任务协议。
- 不把间隔改小当作修复。
- 不每秒调用模型，不按单位各调一次战略。
- 不关副官、不减单位、不降物理帧、不降画质。
- 不覆盖其他会话未提交改动。选址快照分批（`StructurePlacementRuntime` 未编译候选）不属于本假设，未测量前不晋级。

## 2026-10-13 落地

按用户要求跳过改前基线，直接改现有 Python，再开验收局。选址 C# 没有改。`dotnet build G:/AIRTS/AI_RTS/OpenRTS.csproj` 在开局前成功，0 警告 0 错误，工程里原有的选址快照分批一起编过。

侦察：没有确认敌情时，已有机场把无人机目标提到上限 2；空闲机场补 `drone`（意图 `rule-produce-recon`，任务 `rule-produce-drone`）。无敌情或无人机名额没满时，`helicopter` 不占这个名额。无人机产不出来才征用至多一个地面单位。没有敌情点和可见敌人时，作战单位不发 `attack_move`。

战略：runner 注入和战术同一类的 `DecisionScheduler`。图线程只 submit/poll。思考期间规则和 Laya 继续跑。迟到结果要过对局、玩家、计划代际、控制代际和战略纪元，过期不恢复旧目标。库默认 `strategy_review_seconds=0`，runner 默认 10。间隔用测到的 tick 率换算，暂停不按墙钟补发。

计划：`maintain_current` 或任务签名相同则保持。保持不调用 `adopt_plan`，不增加 `plan_version` 和 `plan_adopt_generation`。真正的新计划只替换变化的任务，未提到的旧任务留下，版本只在这时增加。

## 产品口径因此改过的测试

断言没有放宽，变的是输入所代表的局面：

- 已有机场且只有 1 架无人机时，现在要再补 1 架，直到 2 架为止。
- 没有敌情点也没有可见敌人时，不再期待作战单位 `attack_move`。原来测前压轮换、到达优先级、行为树意图 id 的夹具补了敌情点，或给单位挂了在途意图，让阶梯把单位留给行为树。
- 4 米合并桶会把 `[1,1]` 和 `[2,2]` 收成同一格。原先用来表示“不同目标”的点改到 `[20,20]`，仍要求分成两组并保留高优先级。
- 已经记过战略提交时间后，没有计划也不会每拍再进战略。开局时间戳为空仍进一次。
- 模型超时那一拍若观测里没有敌人，规则层不再前压。降级测试改成传入一辆可见坦克，仍要求恰好一条包含 `Unit_1` 的命令。

单测：在 `source/adjutant_coordinator/tests` 跑 development ladder、behavior tree、graph runtime、state channels、intent arbitration、repeat suppression、safe movement、tactical task patch、player interrupt、rules fallback。303 项通过，5 项跳过。

## 验收局

目录：`agent/runs/20261013-strategic-laya/`。数字以 `evidence.json` 为准。同目录 `summary.json` 用关键词计数，会把提示词里的 helicopter 算进去，不能当产量。

第一次拉起没读到本机 `.env.local`，runner 退出码 3（真实 Provider 缺密钥）。日志在 `setup-failed/`。第二次带上 `--env-file`。

- 地图 `PlainAndSimple.tscn`，和平模式，带一个延迟进攻的 AI。
- 服务端 pid 14192，客户端 pid 35296，runner pid 48856。启动脚本退出码 0。收尾时这三个进程都被本轮结束，退出码 1（主动结束，不是自己跑完）。
- 留档 `runner_logs/archive_6870fc14/`，对局 id `6870fc14-b023-4f50-ac67-35cd0603b634`。末 tick 9598。
- 战略调用 5 次，提交 tick 513、2624、4740、6825、8938。间隔约 2111 tick。按这 5 次的墙钟跨度，tick 率约 19.6 Hz，间隔约 108 秒。5 次全部 `ModelTimeout`，单次约 15000 ms。`plan_hold=0`，`plan_adopted=0`。
- 这 108 秒不是 10 秒复核。失败后退避仍用 `--strategy-interval` 的 1800 tick（约 92 秒）再加 15 秒超时。10 秒配置没有在成功复核上被测到。
- 思考期间执行没停：战术模型 171 次全部成功；生产、采集、建造命令在战略超时窗口里继续被接受。
- 机场 `Unit_39` 在 tick 6007 之后存在。侦察生产命令 2 条且被接受：`rule-produce-recon-Unit_39-6111`、`rule-produce-recon-Unit_39-8346`。无人机数量在机场出现后从 0 回到 1，再到 2，之后在 0 到 2 之间波动，没有超过上限 2。整局单位类型里没有 `helicopter`。战斗机生产命令 0。
- 第一条 `attack_move` 在 tick 2825，与第一次看见敌人同一时刻。此前 0 条。看见敌人之后坦克有重复的新 `attack_move` 意图。
- 命令行 160，独立 intent id 126。多出来的 34 条是同一 intent id 的重复记录，重复率 0.2125。这不等于 34 次新的改道。
- 炼油厂有 `NoValidSite` 拒绝，资金一度停在 550，机场因此多次 `InsufficientResources`，后来才建成。这局没有改选址代码。

## 第一局没有证明的事

- 战略模型没有返回过一份计划。维持现计划要等第二局的规则降级证据，不能算模型计划。
- 10 秒复核间隔在这局的成功路径上没有测到。5 秒间隔没有改、也没有测。
- 遇敌后的重复 `attack_move`、侦察无人机换航点，仍会生成新的 intent id。
- 基地受袭、玩家接管、路径失败、另一张地图、10 分钟压力、5 FPS 录像、闭环报告都没有做。
- 收尾之后工程上还有别的 Godot（pid 53524，命令行是另一套安装目录、只有 `--path`）。不是本轮拉起的，没有结束它。

## 2026-10-13 第二局：规则降级，不是模型战略

超时根因：专用模型服务 `127.0.0.1:11436` 这局没有在服务。客户端报「调用方节点尚未进入场景树」，`model_service.log` 停在 2026-10-12 23:22:27，对局请求没有写进去。5 次错误都是客户端等满 15 秒，poll 没有收到成功计划再丢掉。提示词没有改，超时也没有加长。11436 起来之前，不能把这叫做模型战略已修好。

这一局改用已有程序主线（`--strategy-mode rules`，默认仍是 `plan`）。计划 id `rules-mainline-default`。第一次采纳，之后 `maintain_current`。保持不调用 `adopt_plan`。

证据目录：`agent/runs/20261013-strategic-laya/round-02/`。上一局 `evidence.json` 没有覆盖。

- 地图仍是 `PlainAndSimple.tscn`，和平，带延迟进攻 AI。对局 `2eac7bf7-4cde-4dc5-a2f6-646908cf5d11`。
- 服务端 pid 34864，客户端 pid 21536，runner pid 13536。收尾这三个都已结束，退出码 1（本轮主动结束）。当时没有别的 Godot。
- 战略调用 16 次，全部由规则计划返回，`latency_ms` 记为 0。`plan_adopted=1`（tick 498，`rules-mainline-default:v1`，`rules_degraded_adopt`）。`plan_hold=14`，版本字符串始终是这一份。
- tick 1465 有一次结果因 `control_generation` 被拒绝。过期结果仍拒绝。下一次复核继续保持同一版本。
- 发起间隔：第一次 748 tick / 52.9 秒。tick 率测到之后，多数间隔约 200 tick、墙钟约 10 到 14 秒。中间有一次 544 tick / 30.2 秒。默认间隔没有改成 5 秒。
- 第一次保持之后，权威仍接受了生产 7、采集 1、建造 1。战术 92 次里 90 次成功，2 次是在途跳过。
- 单测 `test_rules_safe_plan`：第二次复核不增大 `plan_version`，也不清掉已有采矿任务和在途意图。模型超时降级测试仍要求超时后 `active_plan` 为空。

## 这局没有证明的事

- 模型没有返回过战略计划。规则降级不能写成战略层已修好。
- 5 秒间隔没有改，也没有测。
- 遇敌后的重复 `attack_move`、侦察无人机换航点，仍会生成新的 intent id。
- 基地受袭、玩家接管、路径失败、另一张地图、10 分钟压力、5 FPS 录像、闭环报告都没有做。
- 选址、GPU、工人绕建筑、坦克互撞这一轮没有改。

## 下一步

11436 的模型服务起来之前，不再改战略提示词。模型真正交回一份计划之后，才能把「维持现计划」从规则降级改写成模型战略的对局证据。默认间隔仍不改成 5 秒。
