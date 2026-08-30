# 联机 Demo（2–4 人）：架构·实现·部署（供复核）

> 合并说明（2026-08-30）：本文由原 `联机Demo-架构设计-plan.md`、`联机Demo-2到4人-plan.md`、`腾讯云内测部署-plan.md` 三份合并而成，内容去重后状态以本文为唯一口径。

## Overview

按游戏设计师口径：这是 **不发布的内测 Demo**，目标是 2–4 人连同一局遭遇战一起玩。不用产品级大厅、反作弊、重连、战役联机。

**产品口径（已冻结）：** 2–4 人打同一局 Plain & Simple 遭遇战。战役（回声撤离）保持单机。

**网络口径（已冻结）：** **服务器权威 + 客户端画傀儡 + ENet UDP**。权威进程跑在腾讯云 Ubuntu（4 核 8G / 约 12 Mbps）的一台无头 Godot 上；玩家用 Windows 客户端连公网 IP。这台服务器同时干两件事：**发 Windows 测试包**，以及 **跑这 1 局联机的无头权威服**——不是商店发布，不是多房间平台。

**凭据口径：** 只放工作区根目录 `服务器信息.md`，本文不写密码。

**不要按帧同步（lockstep）做这份 Godot 工程**——理由见下。

相关计划：AI 相关内容统一在 `docs/plan/AI-plan.md`（规则 AI 行为升级 + LLM AI 副官，两套系统）。

## Current State Analysis

### 为什么不能 lockstep

现有单机模拟有三条不可跨机复现的事实：

1. 世界坐标是 `float`（`WorldPosition`），不是定点数。
2. `SimulationClock` 跟真实 `delta`，不是锁死的逻辑帧。
3. 地面/空中寻路走 Godot `NavigationServer3D`，各端各自烘焙、各自避让。

若只同步命令、各端自己跑 Match，几十秒内位置和交战会分叉。因此 Demo **不同步 lockstep**，也不做「只同步输入、各端重放」。

### 工程卡点（设计时必须面对）

- 玩法层原先几乎没有 `ENetMultiplayerPeer` / `@rpc`（仅编辑器插件）。
- `Match.gd` 曾断言全局最多 1 个 Human；HUD / `controlled_units` / 镜头 / 迷雾都绑这一个节点。
- `CommandRuntime` / `UnitCommandGateway` 已按 `issuerPlayer` 做所有权校验，适合作为「只在服务器执行」的入口。
- 图 `PlainAndSimple` 已是 4 人、50×50，正好当 Demo 图。战役（回声撤离）保持单机。
- 家宽 NAT/CGNAT 常见，**不要用某个人电脑当主机**。这台云主机的公网 IP 才是存在理由。
- 带宽够：一局 4 人、10Hz、全量广播约 1 Mbps 量级，12 Mbps 只跑这一局没有压力。迷雾网络过滤、delta 压缩本 Demo 不做。

### 代码与部署进度（复核时请当「现状」而不是「愿景」）

| 项 | 状态 |
|---|---|
| 本机玩家身份、大厅、命令 RPC、10Hz 快照 | 代码已写在 `yyp_test` 工作区，**尚未双进程/公网验收** |
| 云上无头局服 | 已用 Godot 4.7.1 Mono `--headless -- --server` + systemd `airts-game` 拉起，进程在听 **UDP 24567** |
| 腾讯云防火墙 UDP 24567 | **仍需人工在控制台放行**（轻量应用服务器无「安全组」，入口是实例页「防火墙」标签），否则外网连不上 |
| Linux `dedicated_server` 导出包 | 预设已加，**当前云上跑的是工程源码 + 编辑器无头**，不是导出可执行文件 |
| Windows 客户端 zip / nginx 分发 | 未做；测试同学暂用本机 Godot 打开工程 |
| Hermes Dashboard（TCP 80） | 同机另有服务，**与对局协议无关** |
| 部署方式 | 本地打 git bundle 增量 → paramiko SFTP 上传 → 服务器 `git pull` → systemd 重启（脚本在 `临时文件夹/`）；origin 直推 `yyp_test` 待凭据打通 |
| 云主机纪律 | 无 GPU，禁止开 Forward Plus 窗口当「远程试玩」；Godot 自带 SSH remote deploy 依赖 `DISPLAY=:0`，不能用；不叠 CI Runner 和多房间 |

## Implementation Strategy

### 拓扑

```text
玩家 Windows 客户端 × 2–4
  · 镜头、选中、本机 HUD、本机战争迷雾（只挡自己屏幕）
  · 不跑寻路 / 战斗 / 规则 AI / 施工推进
  · 点击 → RPC 命令到 peer 1
        │
        │  ENet  UDP  24567
        ▼
腾讯云 Ubuntu 无头 Godot（专用服，不占 Human 槽）
  · 权威 Match：生成单位、CommandRuntime、NavigationServer、经济、胜负
  · 约 10Hz 全量广播：单位 path、pos、yaw、hp；玩家 resource_a/b
  · 开局后出生/死亡：spawn / despawn RPC
  · 空槽：规则 AI（SimpleClairvoyantAI），只在服务器跑
```

同时只开 **一局**。没有房间列表、没有第二实例。

### 为什么是这套而不是常见替代

| 方案 | 结论 |
|---|---|
| 帧同步 / 只同步命令 | 否。float + 真 delta + NavigationServer 不可复现 |
| 某玩家 listen server | 否。家宽 NAT；Demo 正式测试一律连云 |
| Steam / 多房间 / 中途加入 / 重连 | 否。超出 Demo |
| 服务器只做中继、客户端仍模拟 | 否。仍会分叉 |
| 把 Cursor MCP / Hermes 当「联机通道」 | 否。MCP 是编辑器调试；Hermes 是后来装的 Agent 面板 |

### 职责切分：服务器有什么 / 本地有什么

#### 腾讯云（权威侧）

- 仓库：`/home/ubuntu/AI_RTS`，分支意图钉死 `yyp_test`。
- 进程：Godot 4.7.1 Mono 无头；systemd 单元 `airts-game`。
- 启动：`--headless --path … -- --server`（用户参数 `--server` 走 `NetSession.try_start_from_cmdline`）。
- 监听：UDP 24567（ENet）。专用服 **不占** Human 槽，`local_player_index = -1`，无 HUD。
- 运行时：完整 Match 场景树 + C# `CommandRuntime` / `EconomyRuntime` / `ProductionRuntime` + 两套 `NavigationRegion3D`。
- 同机其它东西（不要和局服搞混）：nginx、Hermes Dashboard（本机 9119，外网 80）、SSH 22。它们 **不参与** 单位移动和伤害。
- **没有：** 显示器上的游戏窗口、玩家键鼠、Forward Plus 出图、公网暴露的 Godot 编辑器 MCP。

#### 每个玩家的 Windows（表现 + 输入侧）

- Godot 4.7.1 Mono 打开同一工程（或以后的 Windows 导出包）。
- 主菜单 → **联机 Demo** → 填云 IP:24567 → 加入 → 准备。至少 2 人全部准备才开局。
- 本机职责：相机、框选、命令栏、把命令发给服务器、按快照改单位 Transform/HP/资源条、本机 FoW。
- 本机 **不** 作为权威：`NetSession.is_client_puppet()` 时吞掉 `Unit.action`、跳过 `Movement` 物理、跳过施工/生产推进、规则 AI `_ready` 早退。
- 单人战役 / 自定义战斗：**完全离线**，不连这台云。菜单仍只允许一个 Human，避免破坏单机。
- 开发自测可用「本机开房」（listen server，主机也是一个 Human）。**给朋友打不要用这个。**

### 会话与开局

1. 专用服启动即 `create_server`。最大客户端数 = 4（专用服自己不是玩家）。
2. 客户端连上后由服务器分配槽位 0..3，RPC 告知 `local_slot`。
3. 每人点准备；`connected_human_count ∈ [2, 4]` 且槽内全员准备 → 开局。**「立即开局」按钮（2026-08-30 用户拍板）**：≥1 人即可跳过等待强制开局，空槽由 AI 补位；未联网时点击会**自动先连云服（`start_solo` → `join(DEFAULT_HOST)`），连上后自动开局**——同时拍板：单人开房也必须走服务器，本机 listen server 仅是开发自测路径（审核更正：原表述「自动先本机开房」与代码不符）。
4. 开局后不接受新玩家（不重连、不中途加入）。注意代码现状与本条原表述有出入：`_on_peer_connected` 在 `_match_started` 后是**静默忽略**而非显式拒绝（复核 P1-3，已补显式拒绝）；掉线处理见复核 Q9（已扶正为「掉线算负、对局继续」）。
5. 所有端用同一份 `MatchSettings`：前 N 个槽 Human，其余 SimpleClairvoyantAI；地图固定 `res://source/match/maps/PlainAndSimple.tscn`。
6. 各端 **各自** 走现有 `Loading.tscn` 实例化 Match（导航要烘焙）。用 Autoload `NetSession` 上的 `notify_match_ready` 握手；**全部 Human 端 Match 就绪后** 服务器才开始快照/出生死亡 RPC。  
   初始单位依赖「同一设置、同一生成顺序、同一节点路径」。开局之后的生产单位走 spawn RPC，不假设客户端自己造出来。  
   **握手必须升级**：`notify_match_ready` 目前只是个布尔，NodePath 错位时客户端 apply 端静默 `continue`（`NetSync.gd` `apply_client_snapshot` 内，约 273 行），错了不报错。客户端 ready 时须上报初始单位相对路径清单哈希 + 版本串（git commit），服务器比对不一致就拒绝开局并打差异（复核 P0-1，✅ 已实施）。

### 身份

- `MatchSettings.local_player_index`：联机 = 本 peer 槽位；专用服 = -1；单机 = 菜单里那个 Human 的下标（或唯一 Human 回退）。
- `Match.get_local_player()` 取代「全局唯一 Human」断言。
- `controlled_units` 只加给 `local_player` 的单位。其它 Human 的 `UnitActionsController` / 蓝图放置在 `Match.ready` 之后禁用，避免 4 个控制器都吃同一点击。
- 命令 RPC **不信任客户端自报槽位**，用 `multiplayer.get_remote_sender_id()` → `NetSession.slot_of`。

### 命令路径

```text
本地 HUD / UnitActionsController
    → NetSession.command_gateway_for(player)
        客户端：NetCommandProxy → NetSync.forward_command → rpc_id(1)
        服务器/单机：真正的 UnitCommandGateway
            → CommandRuntime / UnitCommandService（issuer 所有权校验）
```

生产队列在客户端 `produce()` 会转成 `"produce"` RPC，由服务器再走权威 `ProductionRuntime`。

建造蓝图目前仍是本机 `StructurePlacementHandler` 交互；**把蓝图变成服务器上的施工现场** 仍是薄弱点，复核时请单独看。

### 快照与实体生命周期

- 频率：每 6 个物理帧（默认 60Hz 物理 → 约 10Hz）。
- 通道：`@rpc("authority", "unreliable")` 全量 Array（单位字典 + 资源字典）。Demo 不做视野裁包、不做 delta。
- 带宽估算：一局 4 人、单位量级几十、10Hz 全量，大约 **1 Mbps**；云主机约 12 Mbps 只跑这一局够用。注意单个快照粗估 4–5KB，超 ENet MTU（约 1400B）会分片，任一片丢则整包丢；公网若见规律性卡顿，按单位分组拆 2–3 个 unreliable RPC（复核 P1-4）。
- 客户端 `apply_client_snapshot`：按 NodePath 写 `global_position`、`rotation.y`、`hp`，以及 `Player.apply_authoritative_resource_snapshot`。
- 开局后 `unit_spawned` / `tree_exited` → reliable spawn/despawn。单位网络 ID **暂用 Match 相对 NodePath**，不是稳定 GUID。
- 竞态：全员就绪握手完成（go-live）前服务器模拟已在跑，窗口期内的 spawn/despawn **不会补发**，客户端会永久漏/多单位；go-live 时服务器应广播一次全量单位清单，客户端释放多余、补 spawn 缺失（复核 P1-5）。快照先于 spawn 到达是安全的（apply 跳过未知路径）。

### 刻意砍掉（复核时不要建议「补成产品」除非指出 Demo 会坏）

Steam、房间列表、断线重连、中途加入、多房间、HTML5、战役联机、AI 副官联机、反作弊、锁帧、按迷雾过滤快照、家宽主机作为正式路径。

### 和「Agent 工具」的边界

策划文档里的 Agent = 副官 Observation / Intent / `RemoteLLMPolicy` / `QuerySourceKind.Agent`。  
那是局服本机回环上的后一步，**不是** 本联机 UDP，也 **不是** 已装的 Hermes。联机验收不需要 LLM。详见 `docs/plan/AI-plan.md` Part B。

## Implementation Steps

### 工作包 1 — 本地身份改成「本机玩家」 ✅

1. ✅ 去掉「全局只能有一个 Human」断言。
2. ✅ `local_player`：单机 = 原来的 Human；联机 = 本 peer 分到的槽位。
3. ✅ `controlled_units`、命令栏、镜头、资源条、迷雾只跟 `local_player`。
4. ✅ 单机菜单仍只能选一个人类；联机大厅按槽位分配 2–4 个 Human，空槽规则 AI。

### 工作包 2 — 大厅与连接 ✅

1. ✅ 主菜单加「联机 Demo」：填服务器地址（默认公网 IP）、准备。
2. ✅ 服务器进程 `--server` 监听；人到齐（2–4 且都 Ready）再实例化 `Match`，图固定 `PlainAndSimple`。
3. ✅ 未 Ready 前不进战斗；开局后拒绝新连接。
4. ✅ 空槽填规则 AI。

### 工作包 3 — 命令 RPC + 状态快照 ✅（待双进程/公网验收）

1. ✅ 客户端选中/移动/攻击/建造走 `NetCommandProxy` → `rpc_id(1, …)`，槽位以发送端 peer 为准。
2. ✅ 服务器走现有 `UnitCommandGateway` / `CommandRuntime`，校验发出者。
3. ✅ 10 Hz 广播位置、朝向、HP 和资源；客户端不跑寻路/战斗/AI。
4. ✅ 开局后出生/死亡用 spawn/despawn RPC。
5. ⏳ 本机先做「双进程 listen」验证（一台电脑开 headless + 一个窗口），再上云。

### 工作包 4 — 导出与这台云主机 🔶

1. ⏳ 新增 Linux 导出：`dedicated_server=true`，headless 可执行文件（当前云上跑的是源码 + 编辑器无头）。
2. ⏳ Windows 客户端照常导出（`dedicated_server=false`），排除 `addons/godot_mcp`。
3. ✅ 云主机：`.NET 8`、systemd 拉起无头服（git bundle 部署已运转）；⏳ 防火墙 **UDP 24567** 放行（TCP 22 保留，80/443 归下载）。
4. ⏳ 同一台 nginx 分发 Windows zip；游戏流量走 UDP，不要用 TCP 当对局协议。
5. ❌ 多房间 / 按流量计费当主力 / 把 GitHub Runner 放这台机。
6. ⏳ 安全基线（随时可做）：密钥登录、改密、关密码登录；防火墙收紧（TCP 22 来源限自己、TCP 80/443 下载、UDP 游戏口）。

### 验收顺序

先本机双进程能看见对方移动 → 两台公网电脑打完一局。

## Timeline

| 阶段 | 内容 | 可玩标准 | 状态 |
|---|---|---|---|
| 包 1 | 多 Human 身份 | 单机回归不坏；代码能表示 4 个 Human | ✅ |
| 包 2–3 | 本机双进程 | 两个窗口能互相看见对方单位移动 | 🔶 代码完成（2026-08-29）；⏳ 双进程验收（与工作包 3 第 5 条、Progress 一致：尚未验收） |
| 包 4 | 云上 2 人 | 两台不同网络电脑连公网 IP 打完一局 Plain & Simple | 专用服已上云运行；⏳ 防火墙放行 UDP 24567 后公网试玩 |
| 收尾 | 3–4 人 | 四人槽位、空槽 AI 或禁用；掉线算负、对局继续（不重连） | AI 补位已实施（start_solo，2026-08-30）；大厅「填 AI」开关 ⏳ |

> 空槽规则 AI 的行为升级见 `docs/plan/AI-plan.md` Part A（2026-08-30 立项并过一轮外部评审）。

## Risk Assessment

| 风险 | 缓解 |
|---|---|
| 把现有单机 HUD 直接复制到每个 peer，命令在本地执行 | 输入层只发 RPC；服务器才调 `CommandRuntime` |
| lockstep / 只同步命令 | 禁止。快照以服务器为准 |
| 家宽 listen server | Demo 正式测试一律连云主机 |
| dedicated 导出把导航/碰撞剥掉 | 验收时 headless 必须能走 `CampaignSmokeTest` 同级的导航；只剥渲染 |
| 先上云再写网 | 先双进程，再公网 |
| 下载占满 12M 同时开打 | 开打前下完包；或错峰 |
| C# 在 Linux 无头加载失败 | 与现有 `campaign-regression.yml` 同一 Godot 4.7.1 Mono + `global.json` SDK；SDK 版本必须可复现（见复核 P0-3） |
| 迷雾同步泄露或不同步 | Demo 各端只算自己的 FoW；服务器可全知，不按视野裁包 |
| NodePath 静默分叉 | apply 端对未知路径 `continue` 不报错（`NetSync.gd` `apply_client_snapshot` 内，约 273 行），公网上无法排查；握手清单校验已实施兜底（P0-1） |
| 客户端漏网本地模拟 | `is_client_puppet` 吞 action、停 Movement、停 C# Advance、停规则 AI。遗漏的 `_process` 仍可能改血 |
| `global.json` SDK 版本 | 已 pin `8.0.100`+`latestFeature`（✅ 服务器 8.0.130 解析通过）。教训：rollForward 只向上不向下，本地未提交的 `latestFeature` 改动救不了 8.0.423 的 pin |
| 安全组/防火墙 0.0.0.0 开一堆端口 | 只开一个 UDP 游戏口；口令防扫号即可 |
| 同机 Hermes 占 80 | 不要把游戏改成走 TCP 80；对局保持 UDP |

## Success Criteria

- 2 人（目标 4 人）用 Windows 包连云上无头服，在 `Plain & Simple` 里能看到对方单位、能互相攻击或至少能互相看见移动。
- 测试同学能下载 Windows 包；云上无长期带窗口 Godot 客户端。
- 单机战役 / 自定义战斗原入口仍可玩，不强制联网。
- 不宣称可发布、不接 Steam、不承诺重连。
- 验收层级：人工联机试玩。headless 双进程可作为自动冒烟补一层，但不替代真人 2 机。

## Progress Tracking

- ✅ 工作包 1 本机玩家身份
- ✅ 工作包 2 大厅与连接
- ✅ 工作包 3 命令 RPC + 快照（待双进程/公网验收）
- ✅ 外部 AI 复核吸收 + P0/P1 实施 + 上云（2026-08-29：服务器 HEAD `5be8a3d`，`dotnet --version` 解析 8.0.130 通过，UDP 24567 监听中；本地 push GitHub 待人工凭据）
- 🔶 工作包 4：专用服已上云运行（源码 headless，非导出包）；⏳ 防火墙 UDP 24567、Windows 包分发、dedicated 导出替换
- ⏳ 本机双进程复验、2 人公网试玩、3–4 人试玩

## Related Files

- `source/net/NetSession.gd` — 大厅、槽位、专用服、`local_slot`、握手
- `source/net/NetSync.gd` — 命令 RPC、快照、spawn/despawn
- `source/net/NetCommandProxy.gd` — 客户端 Gateway 外形
- `source/main-menu/Online.gd` / `Online.tscn` — 联机 Demo 菜单
- `source/main-menu/Play.gd`、`source/main-menu/Main.tscn`
- `source/match/Match.gd` — `get_local_player()`
- `source/data-model/MatchSettings.gd` — `local_player_index`
- `source/csharp/GodotAdapter/Input/UnitCommandGateway.cs`
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`
- `source/match/MatchConstants.gd`（Plain & Simple）、`source/match/units/Unit.gd`、`traits/Movement.gd`
- `export_presets.cfg`
- `.github/workflows/campaign-regression.yml`
- `docs/plan/基础功能完善清单.md`（97–99 行已改为 Demo 例外）

---

## 给复核 AI 的说明（请直接评对错，不要扩成产品需求）

你在审一份 **2–4 人、不发布、Godot 4.7.1 Mono、已有大量单机 C#+GDScript** 的 Demo 联机方案。请重点回答下面问题；若某条「可以以后再做」，请标明是否会让 **第一局两人互相看见移动** 失败。

1. **各端各自 Loading 出一份 Match，用 NodePath 当网络 ID**，是否可接受？是否必须改成「只在服务器生成、客户端全靠 spawn」？
2. **10Hz 不可靠全量快照、客户端不插值**，两人互看移动是否够？要不要一上来就 delta / 插值？
3. **战争迷雾只在本机算、快照不裁敌军**，和策划「雾外真值不给 Agent」是否冲突？（联机第一期副官不开。）
4. **空槽填规则 AI（只在服务器跑）** 是否比空着更合适？
5. **当前云上用编辑器无头跑工程**，而不是 `dedicated_server` 导出，对 Demo 是否可接受？
6. 大厅 RPC 放在 Autoload `NetSession`、对局 RPC 放在 Match 下动态节点 `NetSync`，Godot 4 多玩家路径一致性有没有坑？
7. 专用服不占 Human 槽、`call_local` 开局，是否合理？
8. 建造/生产相对移动，哪些必须进第一期，哪些可以坏着？
9. 掉线即整局结束，有没有 Demo 级的更小补丁值得做（例如该玩家单位停手但局继续）？
10. 有没有 **否决项**：不改就会在公网第一局必然失败？

请用「同意 / 有条件同意 / 否决」给总评，并列出按优先级排序的修改建议。不要建议改回 lockstep，除非能证明现有 NavigationServer + float 能确定性重放。

---

## 复核结论（2026-08-29，已对照 yyp_test 实际代码）

**总评：有条件同意。** 架构方向（云上权威 + 客户端傀儡 + ENet UDP）正确，拒绝 lockstep 的论证成立（float + 真 delta + NavigationServer 三处不可复现，无法确定性重放，不再讨论）。无架构级否决项。复核时逐行对了 `NetSession.gd` / `NetSync.gd` / `Match.gd:59-85` / `Player.gd:38` / `global.json`（含 git 未提交改动），不是只评文档。

### P0（公网第一局前必须落地，缺一会挂或挂了没法查）

1. **握手加「初始实体清单 + 版本串」校验**（对应 Q1）。NodePath 方案的失败模式是**静默**：`NetSync.gd:109` 对未知路径 `continue`，表现为"部分单位永远不动/隐形"。修法：客户端 ready 时上报初始单位相对路径清单哈希 + git commit；服务器比对不一致拒绝开局并打差异。约 20 行，把静默分叉变成启动期明示错误。（✅ 已实施并上云 2026-08-29：各端 match_started 时上报排序路径清单，服务器比对，不一致 `_rpc_abort` + 拒绝 go-live）
2. **安全组放行 UDP 24567**（已在清单，纯人工）。（⏳ 待人工操作；注意：这台是**轻量应用服务器（Lighthouse）**，控制台没有「安全组」，对应功能是实例详情页的**「防火墙」**标签 → 添加规则：UDP:24567，允许，来源 0.0.0.0/0）
3. **global.json 改 pin 并推送**。rollForward 只向上不向下，服务器 8.0.130 永远满足不了 8.0.423（本地未提交的 `latestFeature` 改动救不了）；且 Godot 编 C# 走 dotnet CLI，绕不开。推荐 pin 降到 `"8.0.100"` + `latestFeature`（两端都过），改完 commit+push，服务器上 `dotnet --list-sdks` + 试跑一次 `dotnet build` 确认。（✅ 已实施并上云：pin 8.0.100+latestFeature，服务器 `dotnet --version` 解析 8.0.130 通过）

### 逐条回答

**Q1（各端各自实例化 + NodePath 当 ID）：有条件同意。** 不必改成"只在服务器生成、客户端全靠 spawn"——初始实体全走 spawn RPC 只是把风险从"树不一致"换成"启动期大量 spawn RPC 的时序"，工作量更大。真正软肋是错了不报错，P0-1 补上后方案成立。后续优化（P2）：快照键换整型 net id（开局按生成顺序编号，spawn RPC 带 id），顺带砍掉快照里最大带宽项（路径字符串）。

**Q2（10Hz 不可靠全量、不插值）：同意，但建议演示前加插值。** 正确性够，"互相看见移动"成立。两个观感事实：① 10Hz 直接写 transform = 单位每秒瞬移 10 次，移动多的 RTS 看起来像坏了；~20 行两快照线性插值（渲染落后 100–150ms）可解，不阻塞双进程验收，阻塞"拿去演示"。（✅ 插值已实施，见 P1-1。）② 自己下的命令要等 RTT+最多 100ms 才看到自己单位动——无客户端预测的固有延迟，RTS 可接受，**不要**为此上预测。顺带：快照应带服务器帧号——复核时 `NetSync._broadcast_snapshot` 传给 `apply_authoritative_resource_snapshot` 的 version 是客户端本地 `_frame`（恒为 0，`Player.gd` 的版本去重防线形同虚设，死参数）。（✅ 已修复：`_broadcast_snapshot` 现传服务器 `_frame`，`Player.gd` 去重防线已生效。）

**Q3（FoW 本机算、快照不裁敌军）：同意。** 与「雾外真值不给 Agent」不冲突：副官走服务器侧数据源，雾过滤在服务器侧做；第一期副官不开。客户端收全图是已声明的 Demo 取舍，风险表已如实记录，保留。

**Q4（空槽填规则 AI）：有条件同意。** 比空着好：2 人局在 4 人图上有 AI 更像正式对局。条件：做成大厅可选项（默认填）——2 人想纯 1v1 时两个 AI 是干扰。（现状：start_solo 自动补位已实施，大厅开关未做。）

**Q5（编辑器无头 vs dedicated 导出）：有条件同意。** 进程已在听，Demo 可接受。条件就是 P0-3：C# 程序集来源必须可复现。附带代价：进程更重、跑的是源码工程（分支钉死 yyp_test，文档已写）。换 dedicated 导出后「重验导航」保留——预设剥离内容后导航烘焙要重新确认。

**Q6（大厅 Autoload / 对局 Match 下 NetSync）：同意，无结构性坑。** Godot 4 RPC 按接收端节点绝对路径寻址，坑全在路径一致性：① 现状所有端统一走 `_start_loading` 换场景 + `Match.gd:61-63` 统一 `add_child(NetSync)`，路径一致，成立；② 握手日志里打出 `NetSync.get_path()`，公网首连人工核对一次（路径错位的症状是 RPC 静默不到达，极难查）；③ 对局结束 Match 销毁前，服务器先 `_live=false`，否则向已释放路径发 RPC 刷错误。

**Q7（专用服不占槽 + call_local 开局）：同意。** `local_player_index=-1` + `visible_player=0` 回退已正确处理（`Match.gd:73-75`）；HUD/相机在 `_is_dedicated_or_headless()` 下已跳过（`Match.gd:81`）。实现期 checklist 保留：服务器上 `get_local_player()` 返回 null 的所有调用点必须早退。

**Q8（建造/生产哪些进第一期）：** 第一期门槛 = 移动/攻击/资源快照/生产 spawn。建造的命令路径其实已在（`_rpc_command` 覆盖 `construct`/`cancel_construct`），蓝图 ghost 保持本机没问题；验收要盯的是服务器端施工现场实体是否经 spawn RPC 出现在其他端、施工 hp 是否同步——通了建造就基本可用，不通也只是表现缺失，不阻塞移动/攻击验收。「建造联机可能坏」的判断维持。

**Q9（掉线）：有更小的补丁，且现状代码已在事实执行它。** `_on_peer_disconnected` 只弹「本局结束」文案（`_rpc_abort` 只设状态字串），对局实际在继续；掉线者槽位被 erase 后其命令天然被拒（`slot_of` 返回 -1 → `NetSync.gd:163` 拦掉），单位停手。建议扶正这个事实行为：文案改「XX 已掉线，单位停手，对局继续」，胜利判定把掉线者算负。比「整局结束」省掉公网测试最烦的重开成本，也比实现真结束（回大厅、释放 Match）省代码。3–4 人阶段前做完，不阻塞双进程。

**Q10（否决项）：无。** P0 三条是「不改公网第一局大概率挂或挂了没法查」；P1 是体验与健壮性；「刻意砍掉」清单维持，尤其不要回 lockstep。

### P1（双进程能跑，公网前建议做）

1. 客户端两快照插值（Q2）。（✅ 已实施 2026-08-29）
2. 掉线处理扶正（Q9）。（✅ 已实施 2026-08-29，实现取"清空该玩家单位"而非"停手"：歼灭规则 `LastSurvivingSideRule` 依赖 combatant 退出事件，清单位才能让"掉线算负"真正触发结算；2 人局掉线即刻分出胜负，3–4 人局其余人继续）
3. 开局后新连接显式拒绝：`_on_peer_connected` 在 `_match_started` 时静默 return，后来者挂在大厅死等；补 `_rpc_reject` + `disconnect_peer` 两行。（✅ 已实施 2026-08-29）
4. 快照 4–5KB 超 ENet MTU 分片问题，必要时按单位组拆包（见「快照与实体生命周期」节）。（⏸ 未实施，公网观察到规律性卡顿再做）
5. go-live 对账：窗口期 spawn/despawn 不补发，服务器 go-live 时广播全量单位清单，客户端释放多余、补 spawn 缺失（2 人快连概率低，机器慢/人多时上升）。（✅ 已实施 2026-08-29：`_rpc_reconcile`，路径不符的单位生成后校验并移除）

### P2（可以以后）

- 整型 net id 取代 NodePath 键（Q1）。
- ~~快照带服务器帧号，修活资源版本去重（Q2）。~~（✅ 已实施：`_broadcast_snapshot` 传服务器 `_frame`，客户端透传给 `apply_authoritative_resource_snapshot`）
- `resources_payload` 的 `slot` 用 players 组遍历顺序当索引（服务器端 `_broadcast_snapshot`，约 `NetSync.gd:311-317`；客户端 `apply_client_snapshot` 约 286-295 行消费）——两端树一致所以碰巧正确，建议显式带玩家下标。
- ~~`NetSession.gd:193` `dedicated_server = dedicated_server` ……加行注释。~~（✅ 注释已加；现位于 `NetSession.gd:240`：「有意保留专用服标记（self-assign），勿当作冗余代码'修复'」。）
- dedicated_server 导出替换编辑器无头（之后必须重验导航）。

### 本次复核改动本文档的位置及理由

- 「会话与开局」第 4 条：原表述（拒绝新连接 / 掉线整局结束）与代码不符，按代码现状改写并指向修法。
- 「会话与开局」第 6 条：补握手清单校验要求（原握手只有布尔，静默分叉不报错）。
- 「快照与实体生命周期」：补 MTU 分片与 go-live 竞态两条（原节未覆盖）。
- 风险表：global.json 行按事实重写（原行把修法当开放问题；实际 rollForward 不向下滚，只有降 pin／装新 SDK／带 DLL 三条路，且本地改动未提交）；新增「掉线名不副实」「NodePath 静默分叉」两行。（后「掉线名不副实」行在 P1-2 落地、行为扶正为「掉线算负、对局继续」后已删除。）

## Related Plans

- `docs/plan/AI-plan.md`：规则 AI（SimpleClairvoyantAI）行为升级（Part A）与 LLM AI 副官网关（Part B）。规则 AI 只在权威服务器进程思考（`is_client_puppet()` 早退），其行为升级不触碰本文的联机协议与快照契约；唯一联机影响是 AI 单位总量上升放大 10Hz 全量快照体积（见 AI-plan Part A 的 Risk 1）。
