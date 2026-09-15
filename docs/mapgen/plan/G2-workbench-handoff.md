# G2 地貌工作台 → 完整 G1–G4 工作台

> 2026-09-06 更新：工作台已贯通 G1→G2→G3→G4（完整地图任务），G2 版本 **7.5.0**，
> 参数 schema_version 2。主任务与验收见 [RTS-workbench-G1-G4-qwen-plan.md](RTS-workbench-G1-G4-qwen-plan.md)；
> 双执行方分工与交接见 [workbench-team/00-总控与交接.md](workbench-team/00-总控与交接.md)。
> 下文早期“手选出生布局 / 不推进 G3/G4 / 7.3–7.4”等描述仅作历史背景，**当前范围以主计划为准**。

## 使用

在 RTS_Map_Tool 目录双击 `启动地图工作台.bat`，或运行
`.venv-g2\Scripts\python.exe serve_g2.py --port 8766 --open`。
不要用 Anaconda 全局 `python`（本机 NumPy 2.5 与旧 SciPy 不兼容，会在启动时报 `numpy.core.multiarray`）。
（默认 8766；旧 `启动G2工作台.bat`(8765) 保留不动，二者勿同时跑同一输出目录）。

页面提供：

- 主按钮 **生成完整地图**（G1→G2→G3→G4→引擎验收，默认）；辅助按钮 **快速预览地形**（仅 G2 调参）。
- 五组简单选项：玩家距离（不限/近/适中/远）、河流（无/有）、湖泊（无/一个/两个）、
  高地数量（少/适中/多）、通路宽窄（较窄/适中/较宽）。
- **出生布局由系统随机安排**（按玩家距离从合格 G1 池抽取），页面不提供布局选择器；
  生成后只读显示本图布局/地貌编号。高级“按编号复现”用于复现已载入的具体配置。
- 图层页签：最终顶视(G4正交俯视) / 45°轴测(G4正交轴测，验收立体图) / 斜视参考(G4透视，仅观感) / 资源(G3) / 地形逻辑(G2) / 路线(G2)。
- 状态区显示阶段进度（出生布局→地形→资源→场景→引擎验收）与“地图通过/需检查/已中断”。

## 布局来源

现有 `runs/<seed>/G1` 库：64 个布局中 30 个通过 G1 几何检查（近19/适中6/远5），按磁盘扫描，
不硬编码白名单、不重新采样 G1。原始 G1 坐标/territory/manifest 原样复制到任务目录，不写 approved。

## 生成与验收

- G2 7.5.0：构造式湖泊放置（侵蚀口袋候选）+ 贪心中立台地（水域感知公平）+ 封闭口袋填实/
  定向打通；保留平顶台地、3m 高差、坡口、出生 20m 净空、连通与公平检查；湖面积不缩小。
- 完整任务用**显式 auto 模式**跑 G2/G3（校验本次输入而非人工 approval）；manifest 记
  `execution_mode=workbench_auto`，不填 approved。正式 CLI 上游放行检查保留。
- G4：真实高度场（平顶/连续坡/崖脚/岸坡/桥面）→ 导航高度板碰撞 + trimesh 点击/射线；
  场景按唯一 `map_<layout>-<terrain>` 隔离；引擎验收 = Godot 导入 + 正交/斜视截图 +
  定向导航（出生/扩张/台地顶/坡口上下端/桥头/资源 含高度校验）。
- 4AI 五分钟对局为**独立**步骤（smoke_test.gd），未运行如实标注。

## 接口

- `GET /api/bootstrap`、`GET /api/jobs`、`GET /api/jobs/{id}`。
- `POST /api/generate`：body 含可选 `target`（`full` 默认 / `g2`）；省略 layout_seed/terrain_seed 时服务端随机解析一次并持久化。
- `POST /api/jobs/{id}/retry`：同输入重试（从失败阶段继续）。
- `POST /api/jobs/{id}/rebuild_visual`：固定逻辑只重建视觉（visual_seed/profile）。
- `/artifacts/{id}/overview.png|strategy.png|g3.png|g4_ortho.png|g4_oblique.png|config.json|bundle.zip`。
  完整地图的 bundle.zip = 可导入 AI_RTS 的地图包（场景+高度数据+登记项+依赖清单+安装脚本+报告）。

## 验证

```powershell
node --check rtsmap/workbench/static/app.js
python -m pytest tests/test_g1.py tests/test_g2.py tests/test_g2_workbench.py tests/test_g2_choices.py -q
python -m pytest tests/test_g3.py tests/test_pipeline.py tests/test_visual_api.py -q
```

G2 预览不等于 G4 游戏画面；单位动画与实战胜率在对局阶段验证。
