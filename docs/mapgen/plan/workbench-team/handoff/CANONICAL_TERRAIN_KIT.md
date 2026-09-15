# 正式台地与坡道 Kit 基线

## 用户确认

`review/G4/kit_samples/modular_plateau_final/` 是当前审核通过的台地 + 坡道成品参考。它不是历史输出，也不是可删除的临时截图。

## 唯一生成流程

- 生成入口：`tools/godot/modular_plateau_component.gd`
- 基础脚本：`plateau_base.gd`
- 运行环境：带完整资产导入缓存的独立 Godot 预览工程；运行前不得改用空工程或临时白模工程替代。
- 输出：`overview.png`、`ramp_socket.png`、`low_angle.png`、`component.json`

## G4 强制规则

完整 G4 地图生成时，台地和坡道必须按这套已审核组合进行 Kit 化拼装：

1. G2 提供台地边界、坡口方向、坡道长度/宽度和高度锚点。
2. G4 使用同一套台地边缘、崖壁、坡道中段、坡脚和连接件视觉 Kit。
3. 视觉 Kit 只附着到 G2 锚点，不改变 `blocking`、`passable`、`water_footprint`、高度场或导航语义。
4. 导出、截图和实例清单必须记录 Kit 版本、部件角色、锚点、变换、缩放和依赖哈希。
5. 没有台地/坡道 Kit 实例的 G4 地图不视为完成；裸高度场只能作为诊断输出。

## 保护规则

清理脚本和归档操作必须保留整个 `review/G4/kit_samples/modular_plateau_final/` 目录。任何清理前都要检查该路径是否存在，并将其列入保护清单。
