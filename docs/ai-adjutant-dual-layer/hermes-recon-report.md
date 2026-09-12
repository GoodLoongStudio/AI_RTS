# Hermes 只读勘察报告（第三阶段·接入前）

日期：2026-09-07。执行：CodeBuddy（GLM-5.3-Flash）。
授权范围：只读勘察（审查方指示）；原始数据 `G:\AIRTS\tmp_logs\hermes_recon\`，工具 `临时文件夹\hermes_skill\recon_readonly.py`（白名单只读命令，可复现）。
**本轮零修改：未写任何远端文件、未重启任何进程、未改任何配置、未发送游戏命令、未调用任何模型 API。**
本报告不含任何密码/密钥明文；凭据位置以"见本地 服务器信息.md / 服务器 ~/.hermes/.env"指代。

## 1. 版本、会话机制与扩展点（问题 1）

| 项 | 值 |
| --- | --- |
| Hermes Agent | **v0.20.6 (2026.8.27)**，upstream 8d24bc24 + 1 carried commit；git 安装于 `/home/ubuntu/.hermes/hermes-agent`；Python 3.11.16；OpenAI SDK 2.24.0 |
| 常驻组件 | `hermes gateway run`（9/3 起常驻）、`hermes dashboard --host 0.0.0.0 --port 9119`（经 nginx 80 反代对外）、**adjutant daemon**（`/home/ubuntu/adjutant_daemon.py`，监听 127.0.0.1:24580） |
| 会话机制 | `hermes chat -s <skill> --yolo --max-turns 500 -q <prompt>` 单会话进程；看门狗（pidfile `/home/ubuntu/adjutant.pid` + 僵尸感知）自动重开；每条回复必须含工具调用否则会话退出；固定 5s 轮询节奏；交接账本 `/tmp/scout_state.json`、`/tmp/wing_state.json` |
| 扩展点 | ① 技能目录 `~/.hermes/skills/games/ai-rts-commander`（SKILL.md + scripts/rts_ctl.py + handbook/）；② terminal 工具（shell 命令即扩展）；③ 无官方双角色调度 API（架构判断成立：不能假设已有） |
| 模型配置 | `~/.hermes/config.yaml`：provider=**stepfun**，default=**step-3.7-flash**（OpenAI 兼容）；API key 在 `~/.hermes/.env`（权限 600 ubuntu，**未读取内容**）；daemon 另有 ping_llm 直连探测（PROVIDER_DEFAULTS 支持 stepfun/openai/deepseek/moonshot/minimax/anthropic） |

## 2. 真实模型请求应由哪台服务器发出（问题 2）

**结论：服务器本机（101.43.121.102，ubuntu 用户）。**

证据：
- 当前活跃的无人值守副官会话（`hermes chat`，PID 3415975，**勘察时正在指挥真实对局**，22:30 启动）就在服务器上运行，模型请求由该进程直接出网调用 stepfun；
- 对局权威进程（Godot，调试端点 **127.0.0.1:24571**）与宿主同机，命令走回环；
- 调试端点仅绑定 127.0.0.1，本地 Windows 无法直连（做宿主需开隧道=新增暴露面，不推荐）。
- 因此双模型宿主进程应部署在服务器上：模型请求从服务器出网、游戏命令走 127.0.0.1。

## 3. Hermes 能否访问服务端 Provider（问题 3）

**能，且已在用。** 当前会话即由服务器出网调用 stepfun（会话活跃、日志持续产出 rts_ctl 命令）。
daemon 的 `ping_llm` 路由就是现成的 OpenAI 兼容直连探测（`chat/completions`，max_tokens=5），
可复用为 Provider 健康检查。我们的 `ProviderSettings`（api_key_env 机制）与服务器
`.env` 模式一致，接入时只需指向同一环境变量或服务端网关。

## 4. 只读访问清单（问题 4，全部未修改）

- 版本/帮助：`hermes --version`、`--help`
- 进程/端口：`ps aux`、`ss -tlnp`
- 配置：`~/.hermes/config.yaml`（读取输出经 sed 脱敏规则，实际无 key 字段命中）
- 凭证文件：仅 `ls -la` + `stat`（确认 600/ubuntu，**未 cat 内容**）
- 技能：`ls` 技能目录与 scripts
- 日志：`tail -40 ~/hermes_adjutant.log`
- nginx：`cat /etc/nginx/sites-enabled/*`
- 游戏仓库：`git branch/log`（只读）
- 网络：本机 → 服务器 TCP 探测（仅连接立即关闭，未发数据）

## 5. 接入拓扑（问题 8a）

```
本地 Windows (G:\AIRTS)
   │  SSH 22（只读勘察/未来部署）
   ▼
服务器 101.43.121.102 (ubuntu)
   ├─ nginx :80（公网）
   │    ├─ /            → 127.0.0.1:9119（hermes dashboard，登录后含 API Keys 页）
   │    ├─ /adjutant/   → 127.0.0.1:24580（adjutant daemon HTTP）
   │    └─ /adjutant-test/（静态页）
   ├─ hermes gateway run（常驻）
   ├─ hermes chat 无人值守会话（活跃，指挥中）→ 出网 → stepfun API（step-3.7-flash）
   ├─ Godot 权威进程（当前对局）调试端点 127.0.0.1:24571
   ├─ 另一 Godot 调试端点 127.0.0.1:24604（残留/第二进程）
   ├─ adjutant daemon HTTP 127.0.0.1:24580
   └─ UDP 24567 局服（玩家公网入口，安全组放行）
```

双模型宿主建议落点：服务器上新增宿主进程（`HostScheduler`+`HttpModelProvider`+
`ResilientTransport`→127.0.0.1:24571），模型出网请求与现行 Hermes 同路径；
`/adjutant/` 只读路由可作健康检查参考。

## 6. 权限边界（问题 8b）

| 面 | 现状 | 边界判定 |
| --- | --- | --- |
| 游戏调试端点 | 127.0.0.1 only（外网探测 closed） | 外部不可达 ✓；宿主必须与游戏同机 |
| adjutant daemon | 公网经 80 可达 `/adjutant/`（ping/ping_llm/takeover/stop） | **公网可触达会话管理接口**：takeover/stop 若鉴权不足可被第三人操控副官会话（daemon 脚本内置固定 TOKEN，需核实每路由是否强制校验）→ 高优风险 R1 |
| dashboard | 9119 绑定 0.0.0.0（安全组拦外网）+ 80 反代（口令登录） | 口令为弱口令且明文存于本地文档 → 模型 key 泄露面 → 高优风险 R2 |
| SSH | 口令认证 + 口令明文存于本地两处 | 凭据管理散乱 → 中风险 R3 |
| 服务器游戏仓库 | `ad04ddc`（2026-08-31），**落后本地 6+ 天**（无第一阶段协议代码） | 接入前必须同步代码 → 阻塞项 B1 |
| Hermes 凭证文件 | `.env` 600 ubuntu ✓ | 达标；读取 API 需继续沿用"环境变量名注入"模式 |

## 7. 网络路径（问题 8c）

- 模型请求（现状与建议一致）：服务器 hermes/宿主进程 → 出网 HTTPS → stepfun api.stepfun.ai。
- 游戏命令（未来双模型宿主）：宿主进程 → 127.0.0.1:24571（调试端点 adjutant_command）→ 权威执行。
- 只读观测：宿主 → 127.0.0.1:24571（op=rules/tactical/strategic）。
- 玩家：公网 UDP 24567 入局；浏览器：公网 80 → dashboard。
- 本地开发机：**无直达游戏端点路径**（回环绑定），E2E 用的本地双进程拓扑不受影响。

## 8. 风险清单（问题 8d）

| # | 等级 | 风险 | 建议 |
| --- | --- | --- | --- |
| R1 | 高 | `/adjutant/` 公网可达；takeover/stop 为会话管理写操作，daemon TOKEN 硬编码且版本陈旧（线上跑 `/home/ubuntu/adjutant_daemon.py`，本地已有 v5 修复未确认部署） | 接入前核实线上 daemon 版本与每路由鉴权；中期收紧为仅内网/加白名单 |
| R2 | 高 | dashboard 公网（80 反代）+ 弱口令 + 内含 API Keys 页 | 改强口令/加 IP 白名单；模型 key 轮换 |
| R3 | 中 | 服务器 SSH/登录口令明文散落本地多处（工作区根文档、部署脚本） | 收敛到单一凭据管理；报告与提交物不含明文（本轮已遵守） |
| R4 | 中 | **活跃无人值守会话正指挥真实对局**：接入测试若与它并行会双指挥冲突 | 真实 Provider 单次测试前必须先停用该会话（经审查方批准的操作），或使用独立测试对局 |
| R5 | 中 | 端口拓扑文档漂移：SKILL.md 称 AI_RTS_ADJ_PORT 指向 24572，实测当前对局在 24571；另有 24568/24604 残留 | 宿主端口发现必须动态（daemon 注入或 status 探测），禁止硬编码 |
| R6 | 低 | dashboard 9119 绑定 0.0.0.0（依赖安全组兜底） | 改绑 127.0.0.1 由 nginx 反代，消除对安全组单点依赖 |
| R7 | 低 | 服务器技能目录含多个 SKILL.md 备份（bak_5s/bak_v2） | 版本收敛，避免 Hermes 加载歧义 |

## 9. 阻塞项与下一步

**B1（阻塞）**：服务器游戏仓库停在 `ad04ddc`（08-31），无 `adjutant_command`/`rules`/`tactical` 新协议——**真实 Provider 单次只读请求测试前必须先把本地 yyp_test 同步到服务器**（属于写操作，需审查方另行授权并安排停用活跃会话的窗口）。

**建议的"单次只读请求测试"流程（待审查批准后执行）**：
1. 停用当前无人值守会话（写操作，需批准）+ 同步服务器代码（写操作，需批准）；
2. 服务器上以 `mode=http` + 脚本假客户端先冒烟（零网络）；
3. 单次真实请求：`HttpModelProvider` + 真实网关客户端，一次 `propose`（只生成计划，不提交任何游戏命令），结构化日志全程脱敏留证；
4. 结果对照沙盒基线，输出单次请求报告。

## 10. 本轮操作留证

- 勘察工具：`临时文件夹/hermes_skill/recon_readonly.py`（15 条白名单只读命令 + 5 项 TCP 探测，全部只读）。
- 原始输出：`G:\AIRTS\tmp_logs\hermes_recon\recon_20260907_223259.json`（含 config 全文，无 key 字段）、`extra_config_yaml.txt`、`extra_sessions.txt`。
- 约束遵守：未修改远端任何文件/配置/进程；未读取 `.env` 内容；未发送游戏命令；未调用模型 API；本报告不含凭据明文。
