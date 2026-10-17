# 闭环验证报告：单人开不了房（开始游戏无反应）

- 日期：2026-10-01
- 触发：用户反馈「单人不能开房了」
- 状态：`complete`

## 1. 现象与根因

**现象**：单机模式下点「开始游戏」毫无反应，进不了对局。

**证据链**（不是猜的）：
1. 运行日志 `%APPDATA%\Godot\app_userdata\Open RTS\logs\godot.log` 中有：
   `ERROR: Condition "p_scene && p_scene->get_parent() != root" is true.`
   —— 这是 Godot 拒绝**场景切换**的断言：`current_scene` 必须是 **root 的子节点**。
2. 代码里三处都把"新场景"挂到 `get_parent()` 再赋给 `current_scene`：
   - `source/main-menu/Play.gd:73`（点开始 → Loading 场景）
   - `source/main-menu/Loading.gd:119`（Loading → Match）
   - `source/main-menu/MapGeneration.gd:1007`（评图 → Loading）
   当页面被嵌在容器里时 `get_parent()` 不是 root ⇒ 赋值被 `ERR_FAIL` 拒绝 ⇒ 表现为"点了没反应"。
3. 复现探针 `tests/automated/_LobbyStartProbe.tscn`：把 `Play.tscn` 挂到**容器**（父节点≠root）后触发
   `_on_start_button_pressed()`，旧代码下 `current_scene` 不切换；日志出现上面那条断言。

## 2. 改动

| 文件 | 改动 |
|---|---|
| `source/main-menu/Play.gd:73` | `get_parent().add_child(new_scene)` → `get_tree().root.add_child(new_scene)` |
| `source/main-menu/Loading.gd:119` | 同上（`a_match`） |
| `source/main-menu/MapGeneration.gd:1007` | 同上（`loading`） |

## 3. 验证

| 项 | 结果 |
|---|---|
| 探针 `_LobbyStartProbe`（容器挂载、模拟真实点击） | **rc=0**；`父节点=MenuHolder（root? false）` → `current_scene = Loading` → **✓ 开房成功**；无 `p_scene != root` 断言 |
| 全项目启动体检 `--headless --quit-after 240` | rc=0，无 Parse Error / SCRIPT ERROR |
| 真 Match 启动体检（`_RuntimeColliderCheck`） | rc=0，无运行时错误 |

## 4. 顺带发现（非本次改动引起，未处理）

- `assets/map_previews/*.png` 在**工作区被删除**（`git status` 显示 ` D`），导致大厅大量
  `ERROR: Parameter "t" is null.`（地图预览空贴图）。不影响开局，但会刷错误日志。
  属其他会话的改动，未回滚。

## 5. 未验证项

- 未在**可见窗口**里手动点一遍（自动化探针已覆盖同一代码路径）。
- 修复后玩家需要**重启游戏**才会生效（旧实例仍跑旧脚本）。
