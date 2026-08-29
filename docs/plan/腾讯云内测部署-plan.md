# 腾讯云内测部署 Implementation Plan

## Overview

这台 4 核 8G、约 12 Mbps 的 Ubuntu 同时干两件事：**发 Windows 测试包**，以及 **跑 1 局 2–4 人联机 Demo 的无头权威服**。不是商店发布，不是多房间平台。

联机玩法与砍掉范围见 `docs/plan/联机Demo-2到4人-plan.md`。凭据只放工作区 `服务器信息.md`。

## Current State Analysis

- 游戏已有 ENet 大厅 + 权威快照（见联机 Demo 计划）；上云还差：UDP 24567 安全组、无头进程、本机双进程验收。
- 云主机无 GPU，禁止在上面开 Forward Plus 窗口当「远程试玩」。
- 12 Mbps 跑 **一局** 4 人全量 10 Hz 快照足够；不要在这台机上叠 CI Runner 和多房间。
- Godot 自带 SSH remote deploy 依赖 `DISPLAY=:0`，不能用。

## Implementation Strategy

1. **安全基线**（随时可做）：密钥登录、改密、安全组收紧。
2. **文件站**：nginx 提供 Windows 客户端 zip。
3. **游戏服**（代码就绪后）：systemd + Linux `dedicated_server` 导出，UDP 单端口，同时只开一局。
4. **CI 仍用 GitHub Actions**，不搬到这 8G 上。

## Implementation Steps

1. ⏳ 改密、SSH 公钥、关密码登录；安全组：TCP 22（来源限自己）、TCP 80/443（下载）、UDP 游戏口（例如 24567）。
2. ⏳ `服务器信息.md` 不进入 `AI_RTS` 仓库。
3. ⏳ Windows 客户端导出并上传（排除 `godot_mcp`）。
4. ⏳ nginx 静态目录；内测可用 HTTP 基本认证。
5. ⏳ 联机代码本机双进程通过后：Linux dedicated 导出、安装 .NET 8、systemd、UDP 放行。
6. ❌ 多房间 / 按流量计费当主力 / 把 GitHub Runner 放这台机。

## Timeline

| 阶段 | 依赖 |
|---|---|
| 安全 + 下载站 | 不依赖联机代码 |
| 无头服上云 | `联机Demo-2到4人-plan.md` 工作包 3 本机可玩 |

## Risk Assessment

| 风险 | 缓解 |
|---|---|
| 先上云再写网 | 先双进程，再公网 |
| 下载占满 12M 同时开打 | 开打前下完包；或错峰 |
| dedicated 剥掉导航 | 无头必须能寻路 |

## Success Criteria

- 测试同学能下载 Windows 包。
- 2–4 人能连公网 UDP 打完一局 Plain & Simple。
- 云上无长期带窗口 Godot 客户端。

## Progress Tracking

- ⏳ 安全基线
- ⏳ Windows 包 + nginx
- ⏳ Linux dedicated + systemd（代码已写，待导出/安全组 UDP 24567）

## Related Files

- `docs/plan/联机Demo-2到4人-plan.md`
- `export_presets.cfg`
- `.github/workflows/campaign-regression.yml`
