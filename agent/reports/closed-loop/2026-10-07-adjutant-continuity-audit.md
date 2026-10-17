# AI 副官探索、编组与停顿诊断

日期：2026-10-07。状态：**needs-review（诊断已取得证据，产品尚未修复）**。

用户要求快速交接 DeepSeek。本轮没有修改游戏/协调器源代码，没有启动新 Godot Match、调用模型或关闭用户进程；新增计划、实施提示词和只读/纯数据探针。

## 关键结论

不是“完全没有编组”，而是已有能力没有形成有效连续控制链：

1. **控制循环被慢工作阻塞**：战略 `propose_plan` 仍同步；路径 TCP 也同步、单次timeout=8s，查询次数配额不是墙钟预算。今天167轮协调 p50=227ms/p95=4956ms/max=41931ms。不能把最长41.9s全归战略：模型日志只有约3.3–4.4s，剩余需分段计时。
2. **快 Laya 没及时落地**：4次成功解码482.2–586.1ms，却实际4次expired；另2次error，0次ok。快扫/异步模型线程存在，不代表结果接收和执行循环不阻塞。4次选择均GAT/W1，不足以证明模型会优先处理探索队。
3. **主力存在明确零跳 bug**：权威直路只返回起点/终点时，安全中继只取已有拐点；60m合法路线可返回原地且ok=true。纯数据已复现。ROLE_SCOUT直接终点，不能把无人机全部现象归到此bug。
4. **监控缺少主动恢复接线**：连续静止会变active_unknown且继续占用；task_stalled未生产，无任务闲置也不在progress范围。未知不能当失败，但必须有优先对账/恢复。
5. **编组存在，执行主要仍是单兵**：纯数据派生S1含1步兵2坦克。今天最大55己方实体，观测到351条去重移动命令中350单人/1两人，squad_multi=0。只代表已观察子集/现有计数，不断言全局无任何多人命令。baseline军事轨逐单位产生，模型补丁没有成功落地。
6. **尺寸迁移后的策略常量尚未同步核对**：既有测试实际失败SCOUT_TRANSFER_SAFE_M20 < balance最大武器射程40。不能用放宽断言或万能倍率修复。

无人机11个到达事件→下一条观测到的侦察回执，p50=1.383s/max=41.973s。这里是接续延迟，不等于纯闲置（到达容差会提前触发，回执也不等于实际运动）。

## 代码入口

- [nodes.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:971)：同步战略调用；同文件node_ingest、_run_micro_layer、_gate_movement、_consume_fast_events。
- [agent_runner.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/deploy/agent_runner.py:961)：同步路径RPC；_build_scheduler只装战术，run循环单线程处理。
- [movement.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/movement.py:565)：稀疏路径中继选择；主力推进固定14m近似未按真实单位视野取值。
- [progress.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/progress.py:174)：无距离接近进展→unknown，不自动恢复；绕路需区别于停滞。
- [squads.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/squads.py:235)：已有派生/持久编组，不重造系统。
- [rules_fallback.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/rules_fallback.py:3238)：baseline军事轨逐个单位意图；专职侦察可以合理单人。
- [task_patch.py](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_patch.py:246)：模型执行者选项主要按距离，不等于idle/urgent优先队列。

## 本轮证据

- [历史日志复算数据](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-adjutant-continuity-audit/round-01/exploration.json)：记录每个源文件路径、mtime和样本边界；原始归档来自当天13:54-13:59，不是本轮新Match。
- [复算脚本](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-adjutant-continuity-audit/round-01/audit.py)：解析JSONL、命令去重和延迟，rc=0。
- [边界探针](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-adjutant-continuity-audit/round-01/boundary_probe.py) 与 [结果](G:/AIRTS/AI_RTS/agent/runs/2026-10-07-adjutant-continuity-audit/round-01/boundary-result.json)：rc=0，证实零跳、未知占用、无任务不监督、延迟poll过期、已有三人编组。断言是“缺陷确实可复现”，不是“修复已通过”。首次误写plan_route导致rc=1，改为真实plan_safe_route后复跑rc=0，仅改探针。

## 测试与缺口

命令（cwd为`G:/AIRTS/AI_RTS/source`）：

```powershell
& 'G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe' -X utf8 -m unittest adjutant_coordinator.tests.test_explore_frontier adjutant_coordinator.tests.test_task_progress adjutant_coordinator.tests.test_squad_composition adjutant_coordinator.tests.test_async_scheduler adjutant_coordinator.tests.test_laya_s1
```

结果：145 tests，1 failure（20<40）、1 skip，**rc=1，不全绿**。默认Python首次同命令另有14个pydantic_ai缺失error，改用项目已有venv后消失，没有安装依赖/改测试。一次配套文件读取用了错误cwd，没有产生产品写入。

独立只读复核已确认：战略同步、快扫不等于控制隔离、零跳无补采样/调用层位移守卫；path_failed实际不在EMERGENCY集合，不能信过期注释。最终交接要求接手者另用真实独立探针验证修复。

本轮未运行Godot/构建/全量回归，未生成新的游戏截图，没有100/200单位新测或修复后数值。用户要求立即收尾，未扩展实现。共享树大量并行/已有修改全部保留；本轮没有产品candidate，champion未晋级，连续产品未提升轮数不适用。

## 接手入口

直接把 [DeepSeek实施提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-07-adjutant-continuity-fix-deepseek.md) 发给新AI。顺序：最小零跳+测量补丁 → 快慢层隔离 → 到达/停滞优先接续 → 持续小队与Laya候选 → 真实Match完整闭环。不能只调sleep、缩TTL或把14m无限放大。

[计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-07-adjutant-continuity-audit.md) 保留具体阶段和验伪条件。
