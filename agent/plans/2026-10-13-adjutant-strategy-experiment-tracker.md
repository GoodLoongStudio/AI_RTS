# AI 副官战略实验跟踪表

日期：2026-10-13。初始状态：全部待执行，没有新性能/正确率结果。

预算、定义和门槛以 [主计划](2026-10-13-adjutant-strategy-long-experiment-plan.md) 为准；执行者更新本表，原始证据写入本轮唯一run-id。已有诊断不是当前champion验收。

| 记录ID | 阶段 | 组合/内容 | 必需性 | 当前状态 | 原始证据/失败解释 |
|---|---|---|---|---|---|
| R00 | M0 | 工程/模型/设备/版本/端口核验、服务与计时 | 必做 | PASS-partial | 11436 在监听；小请求 6/6、稳态 p50 54ms（`m0_service.json`）；selftest rc=0。**产品接线 blocked: workspace**（agent_runner.py 写入被外部还原） |
| R01 | M0 | 后台录像与输入资格、正常开局退局 | 必做 | PARTIAL | 12 局全部可真实开局、watchdog 收尾、`leftovers=[]`；后台 5FPS 录像 1500 帧/0 补帧（`m5-rec-try2`、`m5-d0-long-rec`）。**未做**：玩家 UI 点选/框选资格、正常菜单退局与换图重开 |
| R02 | M1 | K0新鲜完整规划基线；服务诊断有限取样 | 必做 | PASS | 服务健康后失败形态不再是纯超时：2 分钟局 1 次 `ModelInvalidOutput`(11.2s)；3 分钟局 10 请求 6 合法、**采纳 0**、p50 9.59s/p95 10.84s、3×`control_generation`+3×`no_active_plan` |
| R03 | M1 | A规则/campaign + 同一Laya执行基线 | 必做 | PASS-partial | `--strategy-mode rules` 真实 2 局：采纳 1 + 保持 11/14，15/18 单位。**未做**：与 K0 的同局直接重放对照 |
| R04 | M2 | pilot24快照、独立验证24快照、rubric冻结 | 必做 | PARTIAL | 用**真实对局捕获**的 10 个冻结态势做了 6 方案离线对照（`harvest-k0-01/offline`）；24×2 未做，rubric 未逐场景冻结 |
| R05 | M2 | B模板最小候选、静态/真实Match/旧链路闸门 | 必做 | PARTIAL | 离线 10/10 合法可执行、p50 137ms；**未开真实局**（接线 blocked） |
| R06 | M2 | C候选选择最小候选、同等闸门 | 必做 | PASS-partial | 离线 10/10、p50 106ms；真实局 4 次（13/13、14/14、5/5×2）采纳 8~9、0 错误；置换语义稳定性 0.7（见 C-006） |
| R07 | M2 | K0/A/B/C pilot对照与筛选 | 必做 | PASS | `harvest-k0-01/offline/offline_summary.json` + `comparison.json` |
| R08 | M3 | D评分+按需仲裁pilot，与D0评分消融 | 必做 | PASS | D 与 D0 指标完全相同（仲裁 0 次）→ 按 §11 取更简单的 D0 |
| R09 | M3 | 至多2个入围者独立72请求验证 | 必做 | PARTIAL | 只做了 10 局面的 3 置换（30 请求）；72 请求独立验证集未做 |
| R10 | M3 | E两步窄任务 | 条件 | CANCELLED | 未触发条件（C/D 没有语义重复失败；D0 已达 10/10） |
| R11 | M3 | T既有强模型同接口诊断 | 可选 | UNAVAILABLE | 本机只授权本地 2B；不申请新模型/凭据 |
| R12 | M4 | A+最多2入围者，各3seed短局 | 必做 | PASS-partial | A/C/D0 × seed 11/22 共 6 局配对（3 分钟）；第 3 个 seed 在长局中用 33 |
| R13 | M5 | A+优胜者，2地图×3seed配对验证 | 必做 | BLOCKED | 第二张图未生效（服务端日志仍是 `PlainAndSimple`，种子生效）→ 跨图验证未取得 |
| R14 | M5 | A/优胜者各1长局、性能与退重开 | 必做 | PARTIAL | 8 分钟 + 6 分钟录像长局（seed33）已跑；**未测**：帧 p95/模拟速度/内存同条件对照、录制关/开配对、正常退重开 |
| R15 | M5 | S01–S08异常/边界及玩家接管/迟到结果 | 必做 | PARTIAL | 自然达到 S01/S02/S05 特征；S07 玩家接管、S08 故障注入未做；迟到结果有间接证据（`control_generation` 拒绝 15 次） |
| R16 | M6 | 最终相关/全量回归和独立复核 | 必做 | PARTIAL | 新增合同测试 11/11 rc=0；协调器 1062 项 1 失败（他人 WIP，C-011）；定向 Godot 3/3 rc=0。**未做**：全量 Godot 128 项、独立会话复核 |
| R17 | M6 | 对照结论、默认选择、回退、清理与交付 | 必做 | PASS | 闭环报告 + champion.json + checklist.md；默认选 D0 + A 回退，模型战略未达标如实记录 |

## 执行者状态合同

每45–60墙钟分钟及每轮结束，写 `agent/runs/<run-id>/status.json`，至少包含：

```json
{
  "run_id": "<本轮唯一值>",
  "state": "in_progress",
  "phase": "M0",
  "current_variant": null,
  "current_round": 0,
  "champion": null,
  "candidate": null,
  "no_improvement_rounds": 0,
  "completed_records": [],
  "blocked_records": [],
  "next_action": "核验本轮真实工程/服务/实例身份",
  "source_hashes": {},
  "owned_processes": [],
  "cleanup_ok": "unverified",
  "evidence_paths": []
}
```

本例只是记录合同，尚未创建任何运行实例。champion没有实测时必须null；blocked不能等于failed，TODO不能标pass。

每局 `matches.csv` 至少存 run_id、variant、源码hash、地图/seed/敌方配置、开始/结束tick与权威模拟秒/墙钟秒、关键实体与经济/生产/作战进度、目标变化/停滞、请求与超时/可用率、帧p95/模拟速度、退出方式、cleanup、门禁与证据路径。按局为独立样本，重复决策不虚增局数。

每请求 `requests.jsonl` 存快照hash、信息权限、候选与顺序、provider与scheduler配置、实际选择/响应/finish_reason、合法性/语义/迟到拒绝、耗时与token、采纳plan/task及后续命令关联。保留全部失败与超时，拒绝原因有标签。离线有效请求数与真实Match有效局数分开。

`checklist.md` 记录新发现、复现次数、假设、证据和唯一下一步；`champion.json` 记录门禁、适用范围、hash与精确回退补丁。采样缺项写unavailable；未观察到不自动写0。
