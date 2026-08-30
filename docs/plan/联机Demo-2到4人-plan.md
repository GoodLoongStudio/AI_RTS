# 2–4 人联机 Demo Implementation Plan

## Overview

按游戏设计师口径：这是 **不发布的内测 Demo**，目标是 2–4 人连同一局遭遇战一起玩。不用产品级大厅、反作弊、重连、战役联机。

权威模拟跑在腾讯云 Ubuntu 上的 **一台 Godot Linux 无头进程**；测试同学本机只跑 Windows 客户端。协议用 ENet（UDP）。不同步 lockstep。

凭据仍只放工作区根目录 `服务器信息.md`，本文件不写密码。

## Current State Analysis

1. **没有网络层。** 玩法代码零 `ENetMultiplayerPeer` / `@rpc`。`CommandRuntime` / `UnitCommandService` 已经按 `issuerPlayer` 做所有权校验（`UnitNotOwned`），适合直接变成「只在服务器执行」的入口。
2. **单机写死了一个人类。** `Match.gd` `_get_human_player()` 断言 `human_players.size() <= 1`；`controlled_units` / HUD / 镜头 / 迷雾都绑这一个节点。`Play.gd` 选第二个 Human 会把前一个改成规则 AI。
3. **地图现成。** `Plain & Simple` 就是 4 人、50×50，正好当 Demo 图。战役（回声撤离）保持单机，不进联机。
4. **不能 lockstep。** 位置是 `float`，时钟跟真实 `delta`，寻路是 `NavigationServer3D`。各端自己模拟会在几十秒内跑飞。必须 **服务器权威 + 客户端画傀儡**。
5. **不要让某个人家宽当主机。** 国内家宽常见 NAT/CGNAT，朋友连不进去。腾讯云公网 IP 才是这台机器存在的理由。
6. **带宽够。** 一局 4 人、10 Hz、全量广播单位状态，大约 1 Mbps 量级，12 Mbps 端口只跑这一局没有压力。战争迷雾网络过滤、delta 压缩本 Demo 不做。

## Implementation Strategy

一条最小闭环：

```text
测试机 Windows 客户端 × 2–4
        │  UDP ENet（安全组放行一个端口，例如 24567）
        ▼
腾讯云 headless Godot（dedicated_server 导出）
        权威：Match 场景 + CommandRuntime + NavigationServer
        不跑 HUD / 相机 / Forward Plus 真正出图
```

客户端职责：本机玩家的镜头、选中、下达命令（RPC 到 peer 1）、按快照画画、本机战争迷雾（只藏自己屏幕，不改服务器）。

服务器职责：生成单位、执行命令、战斗/采集/建造、定期广播快照、判胜负。

刻意砍掉：Steam、房间列表、断线重连、中途加入、多房间、HTML5、战役联机、AI 副官联机、反作弊、锁帧 lockstep。

## Implementation Steps

### 工作包 1 — 本地身份改成「本机玩家」

1. ✅ 去掉「全局只能有一个 Human」断言。
2. ✅ `local_player`：单机 = 原来的 Human；联机 = 本 peer 分到的槽位。
3. ✅ `controlled_units`、命令栏、镜头、资源条、迷雾只跟 `local_player`。
4. ✅ 单机菜单仍只能选一个人类；联机大厅按槽位分配 2–4 个 Human，空槽规则 AI。

### 工作包 2 — 大厅与连接

1. ✅ 主菜单加「联机 Demo」：填服务器地址（默认公网 IP）、准备。
2. ✅ 服务器进程 `--server` 监听；人到齐（2–4 且都 Ready）再实例化 `Match`，图固定 `PlainAndSimple`。
3. ✅ 未 Ready 前不进战斗；开局后拒绝新连接。
4. ✅ 空槽填规则 AI。

### 工作包 3 — 命令 RPC + 状态快照

1. ✅ 客户端选中/移动/攻击/建造走 `NetCommandProxy` → `rpc_id(1, …)`，槽位以发送端 peer 为准。
2. ✅ 服务器走现有 `UnitCommandGateway` / `CommandRuntime`，校验发出者。
3. ✅ 10 Hz 广播位置、朝向、HP 和资源；客户端不跑寻路/战斗/AI。
4. ✅ 开局后出生/死亡用 spawn/despawn RPC。
5. ⏳ 本机先做「双进程 listen」验证（一台电脑开 headless + 一个窗口），再上云。

### 工作包 4 — 导出与这台云主机

1. ⏳ 新增 Linux 导出：`dedicated_server=true`，headless 可执行文件。
2. ⏳ Windows 客户端照常导出（`dedicated_server=false`），排除 `addons/godot_mcp`。
3. ⏳ 云主机：`.NET 8`、systemd 拉起无头服、安全组 **UDP 游戏口 + TCP 22**（下载包可用 TCP 80/443）。
4. ⏳ 同一台 nginx 分发 Windows zip；游戏流量走 UDP，不要用 TCP 当对局协议。

## Timeline

| 阶段 | 内容 | 可玩标准 | 状态 |
|---|---|---|---|
| 包 1 | 多 Human 身份 | 单机回归不坏；代码能表示 4 个 Human | ✅ |
| 包 2–3 | 本机双进程 | 两个窗口能互相看见对方单位移动 | ✅ 2026-08-29 |
| 包 4 | 云上 2 人 | 两台不同网络电脑连公网 IP 打完一局 Plain & Simple | 专用服已上云运行；⏳ 防火墙放行 UDP 24567 后公网试玩 |
| 收尾 | 3–4 人 | 四人槽位、空槽 AI 或禁用；掉线算负、对局继续（不重连，掉线语义 2026-08-29 已改并实施，替代本文早先「掉线即结束」口径） | AI 补位已实施（start_solo，2026-08-30）；大厅「填 AI」开关 ⏳ |

> 空槽规则 AI 的行为升级独立立项：`docs/plan/规则AI智能化改造-plan.md`（2026-08-30 过一轮外部评审）。

## Risk Assessment

| 风险 | 缓解 |
|---|---|
| 把现有单机 HUD 直接复制到每个 peer，命令在本地执行 | 输入层只发 RPC；服务器才调 `CommandRuntime` |
| lockstep / 只同步命令 | 禁止。快照以服务器为准 |
| 家宽 listen server | Demo 正式测试一律连云主机 |
| dedicated 导出把导航/碰撞剥掉 | 验收时 headless 必须能走 `CampaignSmokeTest` 同级的导航；只剥渲染 |
| C# 在 Linux 无头加载失败 | 与现有 `campaign-regression.yml` 同一 Godot 4.7.1 Mono + `global.json` SDK |
| 迷雾同步泄露或不同步 | Demo 各端只算自己的 FoW；服务器可全知，不按视野裁包 |
| 掉线 | 该玩家单位停手或判负，整局可结束；不做重连 |
| 安全组 0.0.0.0 开一堆端口 | 只开一个 UDP 游戏口；口令防扫号即可 |

## Success Criteria

- 2 人（目标 4 人）用 Windows 包连云上无头服，在 `Plain & Simple` 里能看到对方单位、能互相攻击或至少能互相看见移动。
- 单机战役 / 自定义战斗原入口仍可玩，不强制联网。
- 不宣称可发布、不接 Steam、不承诺重连。
- 验收层级：人工联机试玩。headless 双进程可作为自动冒烟补一层，但不替代真人 2 机。

## Progress Tracking

- ✅ 工作包 1 本机玩家身份
- ✅ 工作包 2 大厅与连接
- ✅ 工作包 3 命令 RPC + 快照（代码已接上，待双进程/公网验收）
- ⏳ 工作包 4 Linux dedicated + 云主机（安全组需放行 UDP 24567）
- ⏳ 2 人公网试玩
- ⏳ 3–4 人试玩

架构给外部复核的正文：`docs/plan/联机Demo-架构设计-plan.md`。

## Related Files

- `docs/plan/联机Demo-架构设计-plan.md`（服务器/客户端职责、协议、给复核 AI 的问题）
- `source/match/Match.gd`（`_get_human_player`、`controlled_units`）
- `source/main-menu/Play.gd`、`source/main-menu/Main.tscn`
- `source/csharp/GodotAdapter/Input/UnitCommandGateway.cs`
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`
- `source/match/MatchConstants.gd`（Plain & Simple）
- `export_presets.cfg`
- `docs/plan/腾讯云内测部署-plan.md`
- `docs/plan/基础功能完善清单.md`（97–99 行已改为 Demo 例外）
