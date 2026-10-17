# 默认镜头高度调整到 80m

## 目标

把真实 Match 的默认开局正交镜头离地高度从 66m 调整为 80m，保持俯角、地面焦点和正交视野尺寸不变。

## 范围

- `source/match/IsometricCamera3D.gd`：唯一运行时高度锚点 `OPENING_HEIGHT`。
- `source/match/Match.tscn`：编辑器/首帧相机初始变换同步到 80m。

## 验收

- 静态 diff 无空白/结构错误。
- 真实 Match 可读性探针记录 `opening_camera.height=80.0`、`size=46.75`。
- 相关探针 rc=0，且没有因本轮改动新增失败。

## 状态

- [x] 修改运行时常量与场景初始变换
- [x] 真实 Match 探针复验
- [x] 闭环报告
