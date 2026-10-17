# 默认镜头高度 80m 闭环报告

## 结论

已将默认开局镜头离地高度从 **66m** 改为 **80m**。正交 `size=46.75`、俯角 `-45°` 和地面焦点比例保持不变。

## 改动

- `source/match/IsometricCamera3D.gd`
  - `OPENING_HEIGHT: 66.0 -> 80.0`。
  - 同步高度锚点注释，避免后续 Agent 误读旧值。
- `source/match/Match.tscn`
  - 初始相机变换 `y: 66.0 -> 80.0`、`z: 91.0 -> 105.0`，保持 `z-y=25` 的原始地面焦点关系。

## 运行时证据

- 探针：`tests/automated/_RtsReadabilityProbe.tscn`
- 证据：`agent/runs/20261010-camera-height-80-r2/measurements.json`
- 新鲜读数：`opening_camera = {"height": 80.0, "size": 46.75}`
- 结果：`RTS readability probe completed: 0 failure(s)`，Godot rc `0`
- 该探针同时重开了一局并验证单位尺寸、移动到达、工厂生产、机场 Drone 生产和 Scout 拒绝生产，均通过。

## 已知限制

- 探针使用 headless dummy 渲染，日志中有 Minimap 纹理读回错误和退出时资源泄漏警告；它们是既有 headless 渲染环境噪声，本轮没有修改相关代码。
- 本轮未生成可见窗口截图；高度数值已由真实 Match 运行时 JSON 验证。
