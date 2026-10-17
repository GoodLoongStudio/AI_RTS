# 提示词：生产卡片图标尺寸规范（观感大小统一）

## 目标（用户原话）
「现在这些UI的建筑的大小你也规范一下，基地这么小，兵营这么大，都不协调」
⇒ 侧边栏生产卡片里，所有建筑/单位图标的**观感大小**必须落在同一条带上。

## 权威来源（唯一）
- 生成器：`tests/automated/NewUnitsLineupSmokeTest.gd` 的 `_render_normalized_icon()`
  （按包围盒取景 + 迭代收敛到 `ICON_TARGET_FILL = 0.82` + 迭代居中）。
- 图标清单：`source/match/hud/ra3/Ra3Sidebar.gd` 的 `TABS[].items[].icon`（唯一权威 key 清单）。
- 显示方式：`Ra3Sidebar._make_cell()` → `TextureRect + STRETCH_KEEP_ASPECT_CENTERED`
  ⇒ **图内可见内容占比 = 观感大小**，规范只需保证该占比一致。

## 步骤
1. 改生成器：删掉 roster 里逐条手调的 `camera size / aim_y`，改走自动取景；
   roster 补齐 `worker`（矿车）。
2. 窗口化渲染（**必须窗口化**，headless 无渲染）：
   ```powershell
   $exe='G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe'
   & $exe --path G:\AIRTS\AI_RTS --quit-after 200000 res://tests/automated/NewUnitsLineupSmokeTest.tscn
   ```
   看日志里每条的 `[ICON] <key> fill=… center_off=(dx,dy)`。
3. **重新导入资源**（否则游戏仍用旧导入缓存，截图看不出变化）：
   ```powershell
   & $exe --headless --path G:\AIRTS\AI_RTS --import
   ```
4. 核验：`IconSizeStandardSmokeTest`（headless）+ 拼图对照 + 真实侧边栏截图并亲自打开。

## 判据（全部要过）
- TABS 里每个 icon key 都有 PNG；
- 每张 fill ∈ [0.72, 0.92]；
- 居中偏移 ≤ 8px；
- **所有图标 fill 极差 ≤ 0.12**（改前 0.648，改后 0.023）。

## 禁止
- 不要改格子尺寸/布局/造价来"凑观感"（那是另一层，且会牵动 UI 规格）。
- 不要为了让测试变绿而放宽判据；判据要能挡住"大小不协调"复发。
- 不要动 `scout.png`（退役单位、TABS 无引用）。
