# 地形斜线修复复验提示词

只在 `G:/AIRTS/AI_RTS` 开发源码上复验；先读取该工程 AGENTS、工作区边界、闭环验证与 RSI 规则。打包版和用户运行实例不得改动或结束。

问题已定位：Match.tscn 的太阳阴影偏移为 0.3，但旧 `Match._apply_large_map_playable_presentation()` 曾覆盖为 0.04，产生密集地形自阴影斜线。本次已删除这个运行时覆盖。不要把雾气、纹理降质、关闭阴影作为修复。

先核对源码 hash、文件 mtime、真实进程 `--path` 与最终运行时偏移。使用 `agent/runs/20261012-terrain-shadow-fix/driver.py` 开独立实例；每次选择新的 `--label`，它会隔离端口、APPDATA、LOCALAPPDATA，并将 GPU 窗口放在独立桌面。不要注入 OS 输入或抢用户前台。

复验平地图和生成图 `36-1846106761-767a002977`，打开实际截图比较 34/53.25/80/120 四个缩放；同机位将偏移改回 0.04，应能复现斜线，恢复 0.3 后应消失，建筑和无人机阴影仍可见。这些临时属性变更仅限自有探针实例。

同时运行新鲜 headless 真实 Match，验证主基地/无人机出生、真实移动、退局重开及最终 0.3；检查退出码、marker、forbidden output、证据 mtime 和进程清理。需要排查坡面时可使用 `diagnose_remaining.tscn`，勿将探针中的关阴影/关法线写入产品。

已有全量回归存在配表/旧夹具/脚本解析/资源释放失败，不允许修改断言变绿、归零警告或声称全项目通过。闭环报告必须记录实际结果、未验证项和共享工作区其他改动；报告入口为 `agent/reports/closed-loop/2026-10-12-terrain-shadow-fix.md`。
