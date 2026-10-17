# 本机开房僵尸房修复报告

## 现象

截图中的建筑和单位价格全部为 `0`，但 Loading 仍然把 Match 标记为就绪，玩家因此进入了半初始化的“僵尸房”。

## 根因

`config/godot/demo.assets.v1.json` 已引用 `scout`，但 `config/balance/demo.balance.v1.json` 没有对应的 `unitTypes` 和 `productions` 定义。`BalanceConfigRuntime` 加载资产清单失败后，旧代码捕获异常并继续启动，留下空的 `Catalog/Assets`。随后 HUD 查询得到空成本，生产/命令运行时继续访问空配置，产生级联空引用。

本机房主日志里还存在 `_rpc_identity_ack` 对自身发送 RPC 的错误；它不是价格为 0 的主因，但会污染开局诊断。

## 修复

- 补齐默认 `scout` 单位和机场生产定义，并把它加入 `DemoBalanceRequirements`。
- `BalanceConfigRuntime` 改为可观测的失败状态：写入 `initialization_failed/initialization_error` 元数据，提供 `IsHealthy()`，不再以“配置降级继续启动”掩盖错误。
- `Match._ready` 增加硬闸门；配置不健康时设置 `match_initialization_failed`，不创建玩家、不发出 `match_started`。
- `Loading.gd` 在设置 `current_scene` 前检查 Match 闸门。失败时留在加载页显示原因并释放半初始化 Match，绝不进入对局。
- 配置依赖的 `CommandRuntime`、`ProductionRuntime`、`StructurePlacementRuntime` 在配置不健康时跳过服务装配，避免子节点 `_ready` 级联空引用。
- 配置查询接口增加失败安全返回，避免菜单读取不存在的字典键。
- 本机 listen server 对自身身份直接调用 ack 处理函数，避免 self-RPC 错误。

## 验证

| 探针 | 结果 |
|---|---|
| `dotnet build OpenRTS.sln --no-restore --nologo` | 通过，0 错误（保留既有 1 个 nullable warning） |
| `LocalMatchStartupIntegrityTest.tscn` | 通过：配置健康、建筑/单位成本均非零、1 名玩家生成 |
| `LocalMatchFailureGateTest.tscn` | 通过：故意缺失配置时 Match 被阻止且玩家数为 0 |
| `LocalLoadingFailureGateTest.tscn`（以缺失配置启动） | 通过：真实 Play→host→Loading 链路显示失败并关闭本机房间 |
| `SoloStartProbe.tscn` | 通过：单人局 1 名玩家，300 帧后仍运行 |
| `_LobbyStartProbe.tscn` | 通过：真实大厅点击路径切换到 Loading |

Headless 渲染器仍会报告 Minimap 纹理为空的 `Parameter "t" is null`，这是 dummy 渲染器的既有测试噪声，不影响上述开局/配置断言。
