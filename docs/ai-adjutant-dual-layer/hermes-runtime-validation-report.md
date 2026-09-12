# Hermes 集成：服务器隔离运行时验证报告

日期：2026-09-08。执行：CodeBuddy（GLM-5.3-Flash）。
性质：服务器**隔离部署环境修复 + 只读协议验证**。
**真实模型未调用；Hermes 会话未接管/未停止（当前也无会话在跑）；游戏指挥类命令未发送；线上服务零修改；`/home/ubuntu/AI_RTS` 零触碰。**
原始数据：`G:\AIRTS\tmp_logs\hermes_recon\`（runtime_*/fix_*/fix2_*/fullsync_*/lifecycle_*/remote4_*）。
工具脚本：`临时文件夹/hermes_skill/recon_*.py`（全部只读检查或仅写隔离目录，可复现）。

## 1. 隔离运行时方案（最终生效版）

```
/home/ubuntu/ai-adjutant/AI_RTS/          # 隔离部署（快照 c9972c1 = ffa3c9b 全量内容）
  ├─ .godot/                              # 导入缓存：先复制现网（7.2M），后由 --import 增量重建
  ├─ assets/ addons/                      # 素材：部署快照自带 + 本地 git archive(ffa3c9b) 补全 + addons/godot_ai 手工补传
  ├─ .godot/mono/temp/bin/Debug/OpenRTS.dll  # C# 构建产物（dotnet 8.0.130 服务器本机构建）
  ├─ lifecycle_v4.py                      # 生命周期脚本（启动→验证→停止）
  ├─ logs/server_24575.log、client_24578.log
测试对局拓扑：专用服(UDP 24575 / 调试 TCP 24577) + headless 客户端(调试 TCP 24578，
  autojoin→24575)；客户端仅用于 join+start 初始化（round_runner 已验证拓扑），
  不发送任何指挥类游戏命令。
```

关键修正（相对上一轮"缺 LFS 素材"的判断）：
- **本项目未使用 Git LFS**（`git lfs ls-files` = 0，现网与隔离一致）；素材为普通 git 文件。
- "no match scene" 的真实根因有三个：① 隔离目录缺 `.godot` 导入缓存与 C# 构建产物；
  ② 部署快照缺部分素材（音效/logo/模型 fbx——现网 ad04ddc 也没有，需从本地 ffa3c9b 补）
  与被 .gitignore 排除的 `addons/godot_ai` 插件；③ **专用服无人类客户端连接时
  `op=start` 静默无效**（`_launch_match` 在 `connected_human_count() < 1` 时直接 return）。

## 2. 服务器现网运行时检查结果（全部 [只读]）

| 项 | 结果 |
| --- | --- |
| Godot | 4.7.1.stable.mono.official（`~/godot/Godot_v4.7.1-stable_mono_linux_x86_64/`） |
| .NET | dotnet 8.0.130（/usr/bin/dotnet） |
| 现网进程 | ①`--server --debugport 24571`（PID 3426382，当前对局，未受本轮影响）②`--autolobby --debugport 24771`（大厅） |
| 现网 C# 产物 | `.godot/mono/temp/bin/Debug/`：OpenRTS.dll 等齐全 |
| `.godot` 缓存 | 15M（imported 775 项 + mono/ + editor/） |
| Git LFS | **未使用**（0 个 LFS 文件） |
| 现网工作区 | ad04ddc + 脏（`M config/balance/demo.balance.v1.json`、删除 debug_ai_probe* 等）——**他人改动，未触碰** |
| 磁盘/内存 | 161G 可用 / 7.7G 内存（充足） |

## 3. C# 构建结果（隔离目录）

```
cd /home/ubuntu/ai-adjutant/AI_RTS && dotnet build OpenRTS.csproj --nologo -v q
→ Build succeeded. 0 Warning(s). 0 Error(s).（两次构建均成功：15.6s / 5.0s）
产物：.godot/mono/temp/bin/Debug/OpenRTS.dll、AI_RTS.Core.dll 等（逐一确认存在）
```
`AdjutantObservationRuntime.cs` 能被 Godot 加载：规则导出冒烟
（`AdjutantRulesExportSmokeTest.tscn`）在隔离目录 headless 运行
**"completed: 0 failure(s)"，SMOKE_EXIT=0**（共 3 次运行，最终 2 次通过；
首次失败为素材缺失所致，见 §7）。

## 4. 24575/24577 端口启动结果

- 端口预检：24575(UDP)/24577(TCP) 启动前空闲 ✓（不占用 24568/24571/24572/24771 ✓）
- 专用服启动成功：日志 `[DBGCTL] 调试控制端点已启动 127.0.0.1:24577`
- headless 客户端 join 成功（`networked=true`）
- `op=start`（经客户端，round_runner 同路径）→ `{"ok": true}`
- 轮询确认服务器 `match=true`
- **验证结束后按 PID 停止全部隔离进程，`ALL_STOPPED`（零残留）**

## 5. 只读验证逐项结果（服务器本机 127.0.0.1:24577，严格顺序）

| 步骤 | 成功 | match_id | player_id | rules_version | snapshot_id | server_tick | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ① rules | ✅ | `815aabb7-…` | （规则视图无玩家字段） | hash `c710239f…9687b0`（content_version=demo-baseline-2026-08-12） | — | — | unit_types=11、productions=5、constructions=6、skills 全部 adjutant_callable=false |
| ② tactical | ✅ | 同上（一致） | `Player_0` | 同上（一致） | 1 | 941 | entities=20（unit_self×4 + resource×16）；敌情为空（无 AI 对局） |
| ③ strategic | ✅ | 同上 | `Player_0` | 同上 | 2 | 941 | production_relations=5（动态关系齐全）、map_bounds=[50,50] |
| ④ status（旧接口） | ✅ | （旧接口无包头字段） | — | — | — | — | units=4；players：Player_0 human=true 余额可见，其余玩家余额脱敏 -1 |

①→②→③ 的 match_id/rules_version 完全一致（同对局同规则）✓；每步均无 error。

## 6. Git LFS 与 .godot 依赖说明

- **Git LFS**：项目未启用（`git lfs ls-files` 为 0）。隔离环境素材缺失与 LFS 无关；
  真因是部署快照不完整 + `addons/godot_ai` 被 .gitignore 排除。
- **.godot 缓存**：Godot 运行必需（imported 资源 + script class cache + mono 产物）。
  隔离目录必须具备：① 复制现网缓存起步；② `--headless --import` 增量重建
  （快照含新资源时必须执行）；③ `dotnet build` 产出 mono 程序集。
- **永久性缺失文件**（当前部署方式无法自动获得，需入库或部署脚本固化）：
  `addons/godot_ai/**`（.gitignore 排除，本地 267 文件 2.6M，已手工补传）。
- **部署建议**：把上述清单固化为部署脚本（bundle/archive + godot_ai 补传 +
  import + build + 冒烟五步），避免每次手工排障。

## 7. 安全审查复核（仅检查，未修改公网配置）

| 项 | 当前状态 |
| --- | --- |
| /adjutant/ 公网可达 | **仍可达**（80 反代 → 127.0.0.1:24580）——R1 未整改 |
| dashboard 绑定 | 9119 仍 0.0.0.0（外网被安全组拦，80 反代可达）——R2 未整改 |
| 旧 daemon TOKEN | `/home/ubuntu/adjutant_daemon.py` 仍含 1 处硬编码 `TOKEN = ` ——R1 相关未整改 |
| 当前 Hermes chat | **无会话在跑**（昨晚会话已结束；`pgrep 'hermes chat'` 仅命中探查命令自身） |
| adjutant.pid | 悬挂指向 `3427266`（非当前 hermes chat 进程；pidfile 生命周期管理缺陷，R1 一并整改） |
| 端口文档 vs 实际 | 实测：24571=现网对局、24771=autolobby 大厅、24580=daemon、24575/24577/24578=本轮隔离（已停）。SKILL.md 的"指向 24572"表述与实际不符（R5 待修） |
| 隔离实例残留 | **无**（ALL_STOPPED） |

## 8. 未完成事项

1. R1/R2 整改（daemon 升级+鉴权、dashboard 收口、key 轮换）——需用户批准的服务器写操作；
2. `addons/godot_ai` 与部署五步（bundle→传输→import→build→冒烟）固化为部署脚本并入库存档；
3. 第三阶段 untracked 文件（config/http_provider/redaction/sandbox+测试）的 commit 待批准
   ——服务器隔离目录已以快照方式包含同等内容（c9972c1），但 git 历史仍需对齐；
4. 真实 Provider 单次 propose（**[模型调用]**）——边界已按第二阶段方案就绪
   （RecorderTransport 零游戏命令路径），待用户批准后在本隔离拓扑上执行；
5. 旧 SKILL.md 的端口表述修正（R5）。

## 9. 边界声明（逐项）

- **真实模型调用：未执行**（无任何 API 请求；本轮唯一出网流量=SSH 会话与本地→服务器 scp）。
- **Hermes 接管/停止：未执行**（当前本就无会话在跑；未触碰 daemon/gateway/dashboard）。
- **游戏指挥命令：未发送**（rules/tactical/strategic/status 全为只读 op；
  `op=start` 仅用于隔离测试对局初始化，round_runner 同路径，已在报告明示；
  adjutant_command/adjutant_batch 未调用）。
- **线上服务修改：未执行**（现网 24571 对局进程全程运行未受影响；`/home/ubuntu/AI_RTS` 零改动；
  nginx/daemon/dashboard 配置零改动）。
- **凭证：未读取、未打印、未复制**（`.env` 仅 `ls -la`/`stat`；日志与报告无任何密钥/口令明文）。
- 隔离实例已全部停止，零后台残留。

## 追加（2026-09-08）：部署固化与安全整改后复核

- 隔离部署已固化为可重复脚本（deploy_isolated.py + deploy_runner.py）：哈希对账+差异补传+构建/冒烟/unittest/生命周期/四步验证/按 PID 回收。两轮运行 p4_run1b、p4_run2 均 ok=True（首轮对账 332 mismatch 补传后归零；次轮 0 差异），证明可重复、端口清理与失败回收可靠（证据 tmp_logs/hermes_recon/deploy_p4_run1b.json、deploy_p4_run2.json）。
- 安全整改完成后复核：daemon 已运行 TOKEN 环境文件化+统一鉴权版本（硬编码 token 0 处）；/adjutant/ 增加 nginx limit_req（nginx -t successful 后 reload）；泄露测试页已移除；dashboard 改绑 127.0.0.1；无 hermes chat 会话在跑；现网 24571 对局与 /home/ubuntu/AI_RTS（ad04ddc）零改动。公网双视角鉴权实测：无 token 403、错误 token 403、有效 token ping 200。
- 本轮边界：真实模型请求（含 ping_llm）0 次；Hermes takeover 0 次；指挥类游戏命令 0 次。已知影响：token 轮换后旧游戏客户端的副官按钮待更新（见安全整改报告遗留项 1）。

## 边界说法修订（2026-09-08 第二次补充：阶段限定）

本文早前的「线上服务零修改」「本轮零修改」等表述仅适用于**隔离运行时验证阶段**（2026-09-07 勘察与验证），为避免歧义特此修订并统一口径：

- **a. 隔离运行时验证阶段（2026-09-07）**：未修改任何线上配置；仅只读勘察、端口连通探测与本机回环协议验证。该阶段 daemon 只读 status 探测曾访问现网 24571 对局端点（唯一一次，鉴权测试附带），**没有发送任何指挥类游戏命令**（move/attack/gather/produce/build 均为 0）。
- **b. 后续安全整改阶段（2026-09-08，经负责人批准）**：修改了线上 daemon（TOKEN 环境文件化+统一鉴权，文件 /home/ubuntu/adjutant_daemon.py）、nginx（/adjutant/ 增加 limit_req；泄露测试页 /var/www/html/adjutant-test/index.html 移除）、dashboard（9119 改绑 127.0.0.1）。
- **c. 改动现状**：上述 b 阶段改动**全部仍生效**（无一回滚）；原 daemon/nginx 配置备份于 /home/ubuntu/ai-adjutant/backup_20260908/（回滚步骤见 hermes-security-hardening-report.md §4）。现网 /home/ubuntu/AI_RTS（HEAD ad04ddc）与 24571 对局进程自始至终未被修改或停止。

后续引用本文边界结论时，以本节阶段限定口径为准。
