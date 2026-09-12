# 真实 Provider 测试前的安全准备与集成方案

日期：2026-09-07。编写：CodeBuddy（GLM-5.3-Flash）。
性质：**本文件为方案设计与本地只读检查结果，本轮未连接服务器、未启动模型、未修改任何线上状态。**
上游输入：`hermes-recon-report.md`（只读勘察）。

## 0. 分级图例（全文步骤按此五类标注）

| 标记 | 含义 |
| --- | --- |
| **[只读]** | 纯读取，零副作用（本地或远端） |
| **[服务器写]** | 需要服务器写权限（改文件/进程/配置） |
| **[需批准]** | 影响线上运行状态或仓库历史，必须由负责人逐项明确批准后才可执行 |
| **[模型调用]** | 会产生真实模型 API 请求（有 token/费用消耗） |
| **[游戏命令]** | 会向游戏权威端点发送命令（改变对局状态） |

## 1. 本地只读检查结果（本轮已执行，**[只读]**）

1. **基线变化**：本地 `yyp_test` HEAD 已从 `6bcf1a1` 前进到 `33c6921`（22:10 merge origin）。
   第一/二阶段协议代码已由其他工具提交为 **`f59e042`**（22:09，提交信息完整描述交付内容），
   工作区已无未提交的协议文件改动；另有 `06941e3`（__pycache__ 清理 + .gitignore）。
2. **协议标记确认**（本地文件 grep）：`DebugControlServer.gd` 含
   adjutant_command/adjutant_batch/幂等账本/玩家接管通知共 25 处命中；
   `AdjutantObservationRuntime.cs` 含 ExportRules/BuildHeader/ResolveMatchId；
   `BalanceConfigRuntime.cs` 含 --balance-config/--assets-manifest 覆盖。
3. **第三阶段代码仍未提交**：`config.py`/`http_provider.py`/`redaction.py`/`sandbox.py` +
   3 个测试文件为 untracked；本地测试基线 **113/113 PASS**。
4. 推论：**B1 的同步内容比勘察时预期更简单**——第一/二阶段协议已入 git 历史，
   服务器同步退化为"git 层面的版本前进"，无需文件级搬运。

## 2. 服务器隔离 worktree / 部署目录方案（需求 1）

原则：**绝不覆盖现有 `/home/ubuntu/AI_RTS`**（它正在服务当前对局与旧 Hermes 会话），
新协议在独立目录独立端口运行，审查通过后才考虑切换。

### 2.1 本地侧（打包，**[只读]** + **[需批准]** 的 commit）

1. **[需批准]** 第三阶段文件提交入库（单提交，建议信息：
   "第三阶段：HttpModelProvider/红action/沙盒/36 测试"）。不 commit 则后续走 2.3 备选。
2. **[只读]** 本地验证：113 项 unittest + `py_compile` + E2E 21/21（现有命令重跑）。

### 2.2 打包与传输（**[服务器写]**，需批准）

主路径（git bundle，不触碰 origin、不动服务器现有 repo）：
```
本地:  git bundle create adjutant.bundle 33c6921 ^ad04ddc   # 仅增量
       scp adjutant.bundle ubuntu@101.43.121.102:~/ai-adjutant/
服务器: git clone ~/AI_RTS ~/ai-adjutant/AI_RTS              # 独立 clone 现有本地 repo
       git -C ~/ai-adjutant/AI_RTS fetch ~/adjutant.bundle 33c6921:deploy-head
       git -C ~/ai-adjutant/AI_RTS checkout deploy-head
```
备选（bundle 不可行时）：服务器直接 `git -C ~/AI_RTS fetch origin && worktree`——
依赖服务器可达 github，且会前进现有 repo（侵入更大），仅作备选。

### 2.3 服务器侧隔离部署（**[服务器写]** + **[需批准]**）

```
/home/ubuntu/ai-adjutant/AI_RTS/        # 独立部署（clone 自本机 repo，非覆盖）
/home/ubuntu/ai-adjutant/logs/          # 宿主/沙盒/请求日志（独立 run_id）
```
- **独立端口实例**（与现有 24567/24569/24571/24572 全部错开，勘察实测无占用）：
  测试对局 UDP **24575** + 调试端点 TCP **24577**；启动：
  `godot --headless --path ~/ai-adjutant/AI_RTS -- --server --port 24575 --debugport 24577`
- C# 构建验证：服务器 Godot 为 mono 版，部署后先跑一次
  `tests/automated/AdjutantRulesExportSmokeTest.tscn`（headless）确认编译与协议可用。
- 宿主进程（第三阶段 `adjutant_coordinator`）运行于同机，`PYTHONUTF8=1`。

## 3. 同步后必须验证的文件与协议（需求 2）

**文件清单**（部署目录内逐一核对存在 + 内容指纹与本地一致）：
| 文件 | 验证点 |
| --- | --- |
| `source/net/DebugControlServer.gd` | 5 个新 op 分发 + `_adjutant_ledger` + `notify_player_override` |
| `source/csharp/GodotAdapter/Adjutant/AdjutantObservationRuntime.cs` | ExportRules/BuildHeader/ResolveMatchId |
| `source/csharp/GodotAdapter/Configuration/BalanceConfigRuntime.cs` | --balance-config/--assets-manifest 覆盖 |
| `source/match/players/human/UnitActionsController.gd` | `_release_adjutant_leases` |
| `source/adjutant_coordinator/`（除 logs/） | 模块齐全；`python -m unittest discover -s tests` 113/113 |
| `config/balance/adjutant-e2e.balance.v1.json` + `config/godot/adjutant-e2e.assets.v1.json` + `source/match/units/Scout.tscn` | 独立测试配置（沙盒对局用） |
| `tests/automated/Adjutant*SmokeTest.*` | 3 个冒烟可运行 |

**协议验证**（全部 **[只读]**，按第 4 节顺序）：rules 三元组+11 类型；tactical 包头
（match_id/rules_version/snapshot_id/server_tick 连续）；strategic 动态生产关系；
adjutant_command 幂等/PlayerOverride/RulesVersionStale（用不落地的探测命令验证校验链，
不实际执行动作）；op=commands 复核账本。

## 4. 只读验证顺序（需求 3，全部 **[只读]**，失败即停）

```
① rules     as_player=<human>                    → 记录 rules_version(content_hash)/match_id
                                                  断言：11 类实体、5 生产、6 施工、skills 全部 adjutant_callable=false
② tactical  as_player=<human>                    → 断言：包头 match_id/rules_version 与①一致；
                                                  entities 含 command_center(constructed=true)；无 full_vision 字段
③ strategic as_player=<human>                    → 断言：生产关系与①规则一致（tank←vehicle_factory）、
                                                  map_bounds>0、敌情仅来自 last_seen
④ status    （旧接口兼容确认，无 as_player）       → 断言：旧字段齐全（networked/match/units/lite 可用）
```
①②③任一失败 → 停止，产出失败报告（保留真实输出），不进入第 5 节。

## 5. 真实 Provider 单次 propose 测试安全边界（需求 4）

### 5.1 前置硬断言（全部满足才允许执行；任一不满足即中止）
1. **[需批准]** 旧 Hermes 会话已停止（见 R4 步骤），断言：`ps` 无 `hermes chat` 进程、
   `/home/ubuntu/adjutant.pid` 不存在或指向非 hermes 进程；
2. **[只读]** 24577 端口的测试对局 `status.match=true` 且 `players` 无第二个 human；
3. **[只读]** ①~④ 只读验证全部通过；
4. **[只读]** 凭证环境变量已注入（值不出现于命令行/日志）。

### 5.2 测试形态（单次 propose，**[模型调用]**，无 **[游戏命令]**）
- 配置：`mode=http` + `allow_game_commands=false` 硬开关（宿主 submit 前断言）+
  **transport=RecorderTransport**（只记录、不连接游戏端口——物理上零游戏命令路径）；
- 动作：一次 `strategy.propose(context)`（观测=该测试对局 tactical 快照）；
- 断言：outcome=completed → `validate_plan` 通过 → PlanStore 采纳 v1 → 单轮报告；
- 记录：结构化日志全程脱敏（第三阶段机制），请求/响应摘要 + headers 掩码落
  `/home/ubuntu/ai-adjutant/logs/<run_id>/`；
- 不执行：`adjutant_command`、`adjutant_batch`、任何 `op=move/produce/...`；
- 结束：宿主进程退出，测试对局进程回收（**[服务器写]**）。

### 5.3 失败处理
任何异常 → 保留完整脱敏日志与真实失败输出，不重试掩盖；模型侧错误按第三阶段
归一化矩阵落 status/reason，报告如实记录。

## 6. R1/R2/R4/R5/B1 整改步骤（需求 5）

### R1 — /adjutant/ 公网暴露（**[服务器写]** + **[需批准]**）
1. [只读] 核实线上 daemon 版本（`head -20 /home/ubuntu/adjutant_daemon.py` vs 本地 v5）；
2. [需批准] 停旧 daemon → 部署 v5（僵尸感知 + `_EXPECTED_RUNNING` 修复）→ TOKEN 改从
   环境变量读取（不再硬编码）→ 每路由强制校验；
3. [需批准] nginx `/adjutant/` 加 `allow <管理 IP>; deny all;`（或改用非常猜路径+强 token）；
4. 长期：takeover/stop 从公网路由移除，仅保留 ping/ping_llm 只读探测。

### R2 — dashboard 公网 + 弱口令（**[服务器写]** + **[需批准]**）
1. [需批准] dashboard 改强口令（Dashboard 设置页）；
2. [需批准] hermes dashboard 改绑 `--host 127.0.0.1`（nginx 反代已覆盖对外）；
3. [需批准] 模型 API key 轮换（stepfun 后台 + `.env` 同步更新）；
4. [需批准] 可选：安全组移除 80 的必要例外前，先确认玩家/用户访问路径。

### R4 — 双指挥冲突（**[服务器写]** + **[需批准]**；影响正在进行的对局）
1. [只读] 记录当前会话 PID 与对局状态（证据留存）；
2. [需批准] `cat ~/adjutant.pid` 确认 → 停 daemon 会话（daemon stop 路由或 kill）→
   断言 `ps` 无 `hermes chat`、pidfile 消失；
3. [只读] 确认测试对局由新部署目录实例承担（24577），与旧对局进程（24571）无交集；
4. 重启该会话需另行批准（旧链路回归测试时才需要）。

### R5 — 端口拓扑漂移（**[只读]** 为主）
1. [只读] 固化实测端口表（本报告 §5 拓扑图）为唯一事实来源，修正 SKILL.md 的 24572 表述；
2. [只读] 宿主端口发现实现为动态探测（对候选端口发 `op=status` 看 `match`/`networked`），
   禁止硬编码——已纳入 `HostScheduler` 接入清单；
3. [需批准] 清理残留 Godot 进程（127.0.0.1:24604）前先甄别归属（memory 纪律：按
   wmic/命令行确认，不按映像名误杀）。

### B1 — 服务器代码落后（**[服务器写]** + **[需批准]**）
按 §2 隔离部署方案执行（bundle 增量 → 独立 clone → §3 清单验证 → 第 4 节只读顺序）。
现有 `/home/ubuntu/AI_RTS` 在审查批准切换前保持原样。

## 7. 执行顺序总表

| 序 | 步骤 | 分级 |
| --- | --- | --- |
| 1 | 第三阶段文件本地 commit（如走 git 主路径） | [需批准] |
| 2 | 本地 113 测试 + E2E 回归 | [只读] |
| 3 | bundle 打包 + scp 传输 | [服务器写] + [需批准] |
| 4 | 服务器独立 clone/checkout + 端口实例启动 + 文件清单核对 | [服务器写] + [需批准] |
| 5 | 服务器冒烟（规则导出 headless 测试）+ 113/21 回归 | [只读] |
| 6 | R4 停旧会话 | [服务器写] + [需批准] |
| 7 | 只读验证 rules→tactical→strategic→status | [只读] |
| 8 | 单次 propose（RecorderTransport，零游戏命令） | [模型调用] |
| 9 | R1/R2 整改（daemon 升级/dashboard 收口/key 轮换） | [服务器写] + [需批准] |
| 10 | 真实游戏命令（adjutant_command）首测 | [游戏命令] + [需批准]（另行安排） |

## 8. 待用户批准清单（汇总）

1. 第三阶段 untracked 文件的 git commit（序 1）；
2. bundle 打包与传输、服务器独立部署目录创建（序 3–4）；
3. 停用当前无人值守 Hermes 会话（序 6，影响其正在指挥的对局）；
4. R1/R2 整改的服务器配置与凭据变更（序 9）；
5. 真实模型单次 propose 的费用消耗授权（序 8，预计单次 ≤ 数千 token）；
6. 任何真实游戏命令测试（序 10，本轮范围外）。
# [已废弃 / 禁止执行] Hermes 旧接入计划

> Deprecated，2026-09-12 归档。下文服务器操作与批准节点仅记录旧任务，不是本地单模型副官的待办。执行请读[当前入口](../../AI副官_当前执行入口.md)。
