# 512地图河道错位与地表斜纹诊断

日期：2026-10-12，Asia/Shanghai。状态：**diagnosis-confirmed；产品未修复**。

## 结论

用户判断部分准确：河道/台地材质错位确由256到512迁移暴露的材质初始化遗漏造成。密集斜纹另有阴影相关原因，不能将所有问题都称为贴图没放大。本轮只新增诊断探针和文档，未修改产品、地图或shader。

开发根 `G:/AIRTS/AI_RTS`；Git根及新增计划/探针/报告/提示词开发目标检查rc0。运行证据/临时启动器按agent/runs既有证据流程写入；该目录检查分类为generated-or-operational，不作为产品源码。

## 证据

只读核对用户Godot PID43084实际命令行为 `--path G:/AIRTS/AI_RTS`，24579归属该进程。status中的基地 `(119.54,8.1,456.24)` 对应布局36，和截图现象一致。未移动镜头、控制单位或结束用户进程。此身份是本轮快照，不供后续任务按固定PID操作。

独立正常Match场景、四Human玩家，通过正常开局链生成8玩家实体。探针测得：

| 项目 | 无头和Forward+实测 |
|---|---|
| Map.size | 512×512 |
| 地形mesh AABB XZ | 512×512 |
| semantic_span | 512 |
| 逻辑_world_span / _water_span | 512 / 512 |
| **材质mask_world_size** | **256** |
| mask_from_tex | 1 |
| SSAO / 阴影 | false / true |

源码调用次序：`_world_span`初始化256 → `_enter_tree`里 `_apply_material` → `_ready`里再次 `_apply_material` → `_build_water_occupancy`更新_world_span512。材质参数早已复制256，后续没有刷新。shader以世界XZ除以mask_world_size，因而把整张掩码压进半跨度；256以外还会repeat_disable钳到边缘，拉出轴向长色块。视觉水色与逻辑禁行格使用不同投影尺度。

## 已打开的同机位A/B

图片目录：`G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/`。七张均实际打开查看，mtime为本轮00:32:06—00:32:13；每张save_png rc0。

| 图片 | 单独变化 | 观察 |
|---|---|---|
| [01-baseline.png](G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/01-baseline.png) | 当前产品 | 复现直条灰色块、地貌纹理错位及密集斜纹 |
| [02-span512.png](G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/02-span512.png) | 仅mask_world_size改512 | 直条消失，出生点成为平地；斜纹仍在 |
| [03-span512-no-shadows.png](G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/03-span512-no-shadows.png) | 在02基础上关闭sun阴影 | 密集斜纹消失；建筑阴影同时丢失，仅用于诊断 |
| [04-span512-implicit-mip.png](G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/04-span512-implicit-mip.png) | 恢复阴影，采样改自动mip | 斜纹保留，不支持把固定LOD作为主要解释 |
| [05-span512-no-normal-map.png](G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/05-span512-no-normal-map.png) | 恢复shader，仅normal_strength0 | 斜纹保留，不支持仅去法线修复 |
| [06-overview-baseline.png](G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/06-overview-baseline.png) | 俯视旧mask256 | 河道与多数桥梁不对齐，边缘出现笔直拉伸 |
| [07-overview-span512.png](G:/AIRTS/AI_RTS/agent/runs/2026-10-12-terrain512-audit/rendered-01/07-overview-span512.png) | 同俯视mask512 | 河道和桥梁/台地轮廓重新对齐；水色仍偏灰/高光强 |

这些是同一测试局的运行时参数诊断，不是已落地产品补丁。所有图隐藏本测试局战争迷雾以便检查，不能作为正常迷雾验收。新shader仅创建在探针内存，不写产品文件。

## 命令、运行身份与限制

探针：`tests/automated/TerrainMaskSpanAudit.gd/.tscn`；启动器：`agent/runs/2026-10-12-terrain512-audit/run_probe.py`。

```powershell
python agent/runs/2026-10-12-terrain512-audit/run_probe.py
python agent/runs/2026-10-12-terrain512-audit/run_probe.py --rendered
```

- 无头PID36332，19.185秒，engine/runner rc0，输出marker与measurements。dummy纹理读回错误、导航map_index错误保留，不能称严格回归通过。
- Forward+ PID42036，28.213秒，engine/runner rc0；RTX3080Ti，frames_drawn51，正常8实体。导航map_index错误、退出2个ObjectDB/1资源泄漏保留；没有解析或shader编译错误。未测行为/性能，不用这些数值宣称游戏稳定或FPS提高。
- 真正CreateProcessW设置 `WinSta0\\AIRTS_TerrainAudit_38656`；EnumDesktopWindows包含该PID的native HWND1183556，确认私有desktop归属。没有SwitchDesktop/SetForegroundWindow/OS输入，前台句柄开始/结束均135546。只结束自然退出的自己实例。
- 探针 `cleanup_ok=true` 表示units组清空，不等同所有引擎资源无泄漏。两次进程均已退出；尚未验证正常大厅退局/重开。
- 诊断局使用 `--no-adjutant` 关闭本轮DCS，但副官UI仍自行发现了用户24579并读取状态。没有发命令；本轮材质数值从本轮地形节点直接读取，图像来自本轮viewport，因此未用外部局数据证明结果。后续修复测试必须在夹具中禁副官自动发现，不能沿用此隔离缺口。日志中的副官信息不纳入当前Match证据。
- 产品 `GeneratedTerrain.gd` SHA256 `819d3948268fcf32e856a7f284ef6777b6d070f53cf86790fabb2d8c3f788332`、shader SHA256 `ff22d57b105f90e74d528416a00c0be5af38515ca53c8bb749ef272591a7ab02`，运行前后相同。共享其他文件可能在并行修改，本轮未撤销它们。

### 隔离修正后的新进程复验

探针断开本实例AdjutantButton的自动安装回调后，重新执行 `python agent/runs/2026-10-12-terrain512-audit/run_probe.py --rendered --run-suffix 02`。PID43140，26.110秒，rc0；实际native HWND660082在私有desktop `AIRTS_TerrainAudit_42744`，前台句柄开始/结束均463496。

`rendered-02/measurements.json` 实测 `adjutant_installed=false`，日志没有ADJ-DBG/扫描用户端口记录，没有退出ObjectDB/resource泄漏，仍有1条导航map_index错误，故不能称严格全绿。8实体、48帧、cleanup_ok=true，产品两文件hash未变，PID自然退出后不存在。

该轮01/02/03图片均实际打开：仍复现旧直条与斜纹；修mask后直条消失；关阴影后斜纹消失。隔离UI没有改变根因结论。其余四张已生成但不重复声称该轮全部图已查看；完整七图查看证据来自rendered-01。第二轮不是产品候选，仅检验诊断是否受UI隔离影响。

路径/格式检查：新增计划、提示词、报告和探针开发目标均allow/rc0；`git -c core.safecrlf=false diff --check` rc0。新文件另行UTF-8/尾随空格核对；运行中待测GDScript已解析并执行，原始日志保留。不修改产品所以未跑C#构建或产品相关/全量回归。

## 修复方案和未验证项

1. 初始化地图世界跨度早于首次材质绑定，保证材质/逻辑/网格合同一致。禁止仅硬编码512或每帧补刷新。实际ShaderMaterial参数加入256兼容/512正反回归，覆盖远端和全图。
2. 阴影伪影独立候选：检查地形投影、网格绕序/单双面、bias/normal_bias、级联和atlas，以及Match/PerformanceGovernor运行时覆盖。关闭阴影已证实关联，但具体子原因未唯一归因；不把关全部阴影作为正式修复。
3. 保留建筑接触影、山体投影与地形细节，比较镜头近中远和移动。P1后灰水/强高光仍在，不能声称全部水面观感修复。
4. 本轮没有修改产品，未运行四大厅图/所有新随机图视觉遍历、移动跨桥回归、性能对照或全量回归。仅完成所述诊断，不创建产品candidate/champion，连续未提升产品轮数不适用。

可执行交接：[2026-10-12-terrain512-render-corrective.md](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-terrain512-render-corrective.md)。计划：[2026-10-12-terrain512-render-audit.md](G:/AIRTS/AI_RTS/agent/plans/2026-10-12-terrain512-render-audit.md)。
