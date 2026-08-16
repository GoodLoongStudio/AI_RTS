# 程序重构：Godot 退出泄漏归因与修复记录

## 1. 处理范围

本文记录 QA-007 对 Godot 无头测试退出时下列文本的归因与处理：

- `RID allocations ... were leaked at exit`；
- `ObjectDB instances were leaked at exit`；
- `resources still in use at exit`。

本项只处理对象和资源生命周期，不修改导航寻路算法、单位行为或性能策略。

## 2. 修复前基线

2026-08-15 的 `TestPlayerVsAI` 性能场景在功能成功后报告：

| 类型 | 数量/表现 |
|---|---|
| `NavObstacle3D` RID | 2 |
| `NavAgent3D` RID | 2 |
| `NavMap3D` RID | 1 |
| Dummy renderer RID | Material、Shader、Mesh、Texture 各2个，Scene instance 15个 |
| ObjectDB | 41～45个 |
| 仍在使用的资源 | 9～11个 |

详细模式进一步显示，ObjectDB 与 Renderer 残留主要来自15组 `ResourceDecayAnimation` 的 `Node3D`、`GPUParticles3D` 及其材质、网格、曲线和脚本；另有正在播放的 Ogg 音频流。

## 3. 根因与处理

| 根因 | 归属 | 处理 |
|---|---|---|
| `Navigation.gd` 通过 `obstacle_create()` 创建2个地图边界障碍，但从未调用 `free_rid()` | 项目生命周期缺陷 | `Navigation._exit_tree()` 先释放全部脚本障碍 |
| `AirNavigation.gd` 通过 `map_create()` 创建独立空域地图，但从未释放 | 项目生命周期缺陷 | 导航父节点在障碍释放后调用 `AirNavigation.release_navigation_map()`，停用并释放地图 |
| 资源节点监听 `tree_exiting`，整场 Match 卸载时仍向正在销毁的父层级延迟添加消散粒子 | 项目生命周期缺陷 | 创建特效前检查完整祖先链；任一祖先已排队删除则不再创建 |
| 旁白和单位语音在场景退出时仍可能持有 Ogg 播放对象 | 项目生命周期缺陷 | 两个语音 Controller 在 `_exit_tree()` 中停止播放并清空 stream |
| 自动测试在测试协程尚未返回时立即 `SceneTree.quit()`，局部 Godot/C# 包装引用没有清理窗口 | 测试基础设施缺陷 | 新增 `SmokeTestExit`，测试主体返回后等待0.1秒，再统一退出 |

导航 RID 的所有权规则现明确为：由 `NavigationServer3D` 低级 API 直接创建的 RID 必须由创建子系统显式释放；由 `NavigationAgent3D`、`NavigationObstacle3D`、`NavigationRegion3D` 等 Node 创建的 RID 继续交给 Godot 节点生命周期管理。

## 4. 回归门禁

`config/full_regression_suite.json` 现将以下文本列为禁止输出：

- `RID allocations of type .* were leaked at exit`；
- `ObjectDB instances were leaked at exit`；
- `resources still in use at exit`。

因此场景即使退出码为0、功能成功标记存在，只要仍有上述退出残留，也会被完整回归判定为失败。新增自动测试必须通过 `SmokeTestExit.request()` 退出，不能在测试协程内直接调用 `SceneTree.quit()`。

## 5. 最终验证

2026-08-15 执行无 `Skip` 完整命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\run_full_regression.ps1
```

结果：

- `dotnet build`：通过；
- 101项纯 C# 核心测试：通过；
- Legacy 权威审计：通过；
- 31个 Godot 自动场景：全部通过新的退出泄漏门禁；
- 合计34/34通过，0失败；
- 本地摘要：`.test-results/full-regression/20260815-233015/summary.json`。

另外，完整 `TestPlayerVsAI` 性能场景专项复测的 stderr 为空。QA-007 至此关闭；后续如果出现新的退出残留，视为普通回归失败，不再使用“既有泄漏”作为白名单。
