# 修复512地图的材质掩码错位与阴影条纹

用户目标：河道、岸线、台地和山体材质与真实地形吻合，地面没有密集斜纹，同时保留建筑/单位阴影与画质。开发根 `G:/AIRTS/AI_RTS`。

先读 `AGENTS.md`、`skills/airts-workspace-boundaries/SKILL.md`、`agent/manifest.json`、`skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md`、`skills/airts-performance-optimization/SKILL.md` 和 `references/render-candidates.md`。参考报告 `agent/reports/closed-loop/2026-10-12-terrain512-render-audit.md`；不能把本次诊断截图当你的新修复验收。

## 已证实的两个问题

1. `GeneratedTerrain.gd` 初始化 `_world_span=256`。`_enter_tree` 和 `_ready` 里的 `_apply_material` 都早于 `_build_water_occupancy`；材质 `mask_world_size` 因此绑定256，之后逻辑跨度更新512却不重新绑定。真实Match探针得到 Map512、mesh512、semantic512、logic512，但shader mask256。只在测试局将该参数改512，出生地直条色块消失，俯视河道重新和桥梁/高度场对齐。这是256到512迁移暴露的初始化次序缺陷，不能通过重新扩大贴图、挪河道或调整单位解决。
2. 材质跨度正确后，密集斜纹仍存在。仅在诊断局关闭方向光阴影，斜纹消失；更换 `sample_tiled` 的固定LOD为自动LOD、将 `normal_strength` 置0均未消除。当前SSAO已是false。因此定位为阴影相关伪影；具体阴影偏移、级联、网格绕序/投影状态尚未唯一归因，不能直接宣称是贴图分辨率或SSAO。

完整对照：`agent/runs/2026-10-12-terrain512-audit/rendered-01/`，01旧图、02仅修mask、03关阴影诊断、04自动mip、05无法线、06旧俯视、07修mask俯视。诊断探针 `tests/automated/TerrainMaskSpanAudit.gd/.tscn`。

## P0 保护与基线

核对Git根、工作区目标、文件当前mtime/diff/hash；工作区有其他会话修改，只精确编辑自己部分。保存新run_id和基线。用户PID43084只是诊断时的身份记录，不是可清理或固定可复用目标。

诊断脚本的早期 `--no-adjutant` 样本中，AdjutantButton仍扫描了用户24579读取状态。这说明该参数并不能隔离UI轮询。当前探针已在本实例断开自动安装回调，rendered-02实测adjutant_installed=false、无端口扫描日志且根因复现不变。新探针继续保留该隔离，并确认日志没有扫描用户端口；需测试副官时才另用真正仅指向本轮独立DCS的机制。不改生产副官、不中断用户模型，不把用户局返回的状态计入本轮证据。

辅助控制台启动隐藏；可见渲染使用可靠私有desktop或后台非激活窗口，不抢前台、不发OS输入、不warp_mouse。私有desktop必须通过真实CreateProcessW的lpDesktop传递，枚举并核对实际HWND所属desktop；`subprocess.STARTUPINFO.lpDesktop`动态属性不能代替它。现有诊断启动器使用 `tools/dev/debug_tcp_remaining_gates.py::OwnedProcess`，不要盲目复用有问题的旧启动器。

## P1 最小材质跨度修复

修改范围优先 `source/match/maps/generated/GeneratedTerrain.gd`。在第一次绑定材质之前从当前地图合同初始化世界跨度，材质与水域逻辑共享同一有效值。不只在_ready最后补一次刷新造成首帧错误，也不新增每帧更新/读取图片。

不要把256字面量简单替换为512：仍保留合法历史256地图的跨度和现有语义域/世界变换合同。正常新图512、root scale1；`semantic_span`、世界跨度和网格数据点数是不同含义，不能把513个点当513米。核对场景读取时序，不能在父级尚不可用时静默回退256。

新增有效回归断言：入树后**实际ShaderMaterial参数**等于地图世界跨度；不仅断言内部 `_world_span` 已更新。覆盖四个大厅地图、当前安装的新随机图和合法256兼容夹具；取至少一条河道/两岸/台地内外/桥头及 x或z>256 的样本，着色掩码坐标与逻辑mask/heightfield位置一致。记录初次绑定和_ready后的值，避免晚刷新掩盖首帧。

补丁后解析/必要编译，新进程真实Match验证出生、移动/过桥一条旧链路、退出；正常迷雾截图与几何诊断截图分开。若出现新错误即拒绝候选，只撤自己的改动。

## P2 单独诊断和修复阴影条纹

先保持P1正确，建立相同相机位置/正交size/光照/分辨率的阴影A/B，不同时改曝光、材质颜色、贴图尺寸或镜头。

核对写入者：`Match.gd::_apply_large_map_playable_presentation` 当前设置shadow_bias0.04、normal_bias1、pancake8、max_distance80；`PerformanceGovernor._apply_tier` 还会改shadow atlas、开关和max_distance，不能只改tscn被运行时覆盖。`showcase_land` 双面绘制且GeneratedTerrain历史注释指出网格绕序与review相反，这是要测的候选原因，不是已证实根因。

在独立探针中一次只变一个因素：地形投射阴影开关、阴影正反面/网格绕序、合理bias/normal_bias、级联范围和atlas。地形单独停止投影用于定位，不能直接作为最终修复：山体给地面投影仍需保留。更改网格索引也可能影响导航/物理/法线，除非证据确认必要，否则优先更小的表现补丁。

以最小可靠修改消除伪影，保留建筑/车辆接触影和山体投影，不能通过关闭全部阴影、削平地形/法线、模糊贴图或改变游戏尺度凑绿。检查近、中、远三档缩放和镜头平移，坡面/桥面/水岸/模型脚底；防止阴影悬浮、漏光、级联接缝和远近切换闪烁。参数来源保持一致，不复制出第二份仅某次运行有效的覆盖。

P1对齐后水色仍可能偏灰/高光过强；本轮诊断并未将它单独归因。先核对真实水域材质和光照，单立候选，不能用提高蓝色饱和度掩盖阴影/岸线错误。

## P3 验收与交付

每个关键产品补丁后新进程真实Match，测受影响正反行为及至少一条旧轨迹；相关回归优先地图尺寸/合同、terrain-ground-collision、navigation-stability、fog-of-war-sight-range。历史失败保留归因，不能删forbidden或改判据凑绿。按仓库要求最终回归并独立探针复核；不扩展成寻路重构或修全部历史故障。

可见验证至少：四大厅图和一新随机图的全图俯视、四出生点、桥头/坡道/远端河道、正常迷雾开局。低帧率短视频或连续截图检查镜头移动时条纹/阴影闪烁；保留不录制时相同场景帧时间对照。静态截图必须实际打开，范围正确且产物新鲜。

最终报告列：改动文件、基线/新材质跨度、阴影最终生效参数及写入来源、各A/B因素、已打开截图/视频、测试命令/rc/marker/forbidden、原始错误、性能同条件比较、源hash、实例/端口/Match ID与cleanup。分别标记坐标对齐、阴影质量、相关回归、整体验收。没全绿不称全项目champion；未测全图不能说所有贴图都修复。

从P1确定的初始化缺陷开始，P2独立处理；不重新乘2地图/单位，不批量重新生成已修改地图，不修改交付打包版。
