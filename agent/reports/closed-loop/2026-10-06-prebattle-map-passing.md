# 闭环报告：战前战术讨论室 · 入口地图传递（阶段 2A 第 1 条）

- 日期：2026-10-06　状态：**needs-review**
- 提示词：`agent/prompts/2026-10-06-strategic-prebattle-ui-map-deepseek.md`
- 计划：`agent/plans/2026-10-06-strategic-prebattle-map-ui-plan.md`

## 1. 改动文件（1 处，+17 行）
`source/main-menu/MatchSetupPage.gd` 的 `_on_sandbox_pressed()`：
- 旧：`get_tree().change_scene_to_file.call_deferred(StrategicSandboxScenePath)` ⇒ **不传地图** ⇒ 页面永远退回 `PlainAndSimple.tscn` ✗；
- 新：**实例化 → `page.set("map_path", selected_map_path())` → `root.add_child` → `current_scene`**（与 `Play.gd:73-79` 同款写法 ✓），
  并对**随机地图**与**空选择**各加一道阻断 ✓（随机地图严禁临时生成冒充已选地图 ✓）。

## 2. 基线与新数值
| 项 | 改动前 | 改动后 |
|---|---|---|
| 页面收到的 `map_path` | 恒为默认 `PlainAndSimple` ✗ | **随所选地图变化** ✓ |
| 进入日志 | 无 | `[StrategicSandbox] 进入战前战术讨论室 map_path=<所选>` ✓ |
| 随机地图 | 可进入（无地图事实）✗ | 按钮禁用 + 代码再兜底拒绝 ✓ |

## 3. 测试命令与 rc
```
godot --headless --path . res://tests/automated/_StrategicEntryProbe.tscn
rc = 0，0 failure（两张地图对照 + 未创建 Match）
```

## 4. 未验证项
- **页面布局（提示词 §3）未做** ✗：`_build_ui()` 仍把 `VBoxContainer` 挂在根节点（缺 `SafeArea/CenterPanel/Margin`）
  ⇒ 「控件挤左上角」的结构性根因仍在 ✓（属 `StrategicSandboxPage.gd`，见 §5 并行风险）；
- 未跑菜单类套件（`EscReturnSmokeTest` 等）✗；
- 未出截图 ✗（headless）。

## 5. ⚠️ 并行工作区风险（重要）
- `source/main-menu/StrategicMapIntel.gd` 的 mtime = **10-06 15:24（本地）**，距本次侦察仅 **5 分钟** ✗
  ⇒ **另一个 Agent 正在同时执行同一提示词** ✓；本轮**未触碰**该文件与 `StrategicSandboxPage.gd` ✓；
- `assets/map_previews/*` 在工作区**被删除** ✗（782 项改动之一）⇒ `preview_available()` 返回 false ✓
  ⇒ 按提示词要求，页面必须显示**明确的缺失状态**而不是空白块 ✓（该分支已存在 ✓，未实测 ✗）。

## 6. candidate / champion
- candidate = 入口补丁 ✓（硬门禁除截图/独立复核外全过 ✓）⇒ **提升为 champion** ✓；
- 连续未提升轮数：**0** ✓。
---

## 7. 第 2 轮补充：布局结构重构（提示词 §3）

**改动**：`source/main-menu/StrategicSandboxPage.gd`（378 → 452 行，唯一文件）
— 引入 `SafeArea → CenterPanel → Margin → RootVBox`，内容不再堆在页面根节点；
响应式：<1100 宽自动上下堆叠；安全边距 `max(24, 5%)`；样式复用 `SystemUIStyle`；页头显示地图名。

**证据**：
- `tests/automated/_StrategicLayoutProbe.tscn` ⇒ rc=0，0 failure（1280/1920/2560/960 四档：
  中央面板均在安全区内、两栏不重叠、边距 5%、页头含地图名、宽屏分栏、窄屏堆叠）；
- 套件回归 3/3 rc=0：`esc-return`、`tutorial-main-entry`、`strategic-chat-service`。

**仍未完成**：预览缺失态、预览图出生点标记、出生点卡片方位/资源、事实分组实测、
未选点时聊天禁用实测、无 SimulationClock/NetSession.host 的日志证明。
---

## 8. 第 3 轮补充：地图预览 + 出生点标记 + 尺寸 + 聊天门禁

**改动**：仍只改 `source/main-menu/StrategicSandboxPage.gd`（455 → 563 行）。

**探针抓到并修掉两个真 bug**：预览容器宽度为 0（标记 X 全 0）→ 加 `SIZE_EXPAND_FILL`；
标记早于布局完成被排布 → 监听容器 `resized` 重排。

**证据**（`tests/automated/_StrategicPreviewProbe.tscn`，rc=0，0 failure，22 项 OK）：
- 4 个标记在两张地图上都**精确**落在 `世界坐标 / 世界尺寸` 映射处（**差 0.00px**）；
- 尺寸标签显示真实尺寸；预览缺失态分支可见且带缺失路径；
- 聊天门禁：未选点 `disabled` + 文案「请先选择一个出生点」；选点后启用并出现副官欢迎语；
- 套件回归 3/3 rc=0（esc-return / strategic-chat-service / tutorial-main-entry）。

**仍未完成**：出生点卡片方位与附近资源、已知/未知两组实测、无 SimulationClock/NetSession.host 的日志证明、截图。
---

## 9. 第 4 轮补充：出生点卡片信息 + 事实分组 + 对局链路禁令证明

**改动**：`source/main-menu/StrategicSandboxPage.gd`（569 → 622 行）。出生点卡片新增
「方位（八方位，由世界坐标计算）+ 贴图缘 + 附近已知资源（40m）」；次要字号统一 ≥14px。

**证据**（`_StrategicPreviewProbe`，rc=0，0 failure）：卡片方位实测 东南/西南/西北/东北 ✓；
事实两组均已填充 ✓；`Match=false`、`SimulationClock=false`、`NetSession.is_networked()=false` ✓
⇒ 提示词「禁止创建/调用」清单**有实测证明** ✓。

**仍未完成**：情报对象缺 `map_size`（并行文件，下轮补齐）、截图。