# 计划：建造范围圈缩到 2/3

- 状态：`needs-review`
- 用户指令：建造圈「有 2/3 现在的半径就够了」⇒ `BuildRangeMeters` 18 → **12**。
- 权威来源：`GodotStructurePlacementWorldPort.cs:36`（唯一 ✓，圈与判据同源 ✓）。
- 验证：解析/编译 ✓ → 真实 Match 探针测**接受/拒绝边界**（正向 + 反向成对 ✓）
  → 相关套件 ✓ → 截图 ✓ → 闭环报告 ✓。
- 不做：不在 GDScript 另写半径 ✗、不改放置判据的口径 ✗、不动 footprint ✗。