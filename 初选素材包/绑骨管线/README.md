# 角色动画管线

4006 当前可用基线为 [原厂骨架 v3](4006/原厂骨架_v3/README.md)，包含一个标准士兵的七段动画、Blender 工程及 Godot 审核工程。重建和验证请使用 [native_pipeline](native_pipeline/README.md)。

批量角色基线见 [批量绑定_v1](批量绑定_v1/README.md)：一战军人（德/英）、幻想怪物
（MechanicalGolem/ElementalGolem/FortGolem）、4006 全部 15 个科幻角色，每角色七段
动画与逐段 GIF/胶片条，由 `native_pipeline/build_batch.py` + `validate_batch.py` 重建并
验证，全部 PASS。怪物为近战持棍（Fire 用 UAL Sword_Attack），步枪角色按各自武器握持。

- `4006/原厂骨架_v3/动画审核/`：当前动画预览。
- `mocap/`：保留的动作源，v3 仍依赖其中的 Soldier 和 UAL 数据。
- `build_ual_gltf.py`、`unpack_pck.py`：保留的动作源转换/提取工具。
- `463/`：其他素材包，本次 4006 清理不涉及。

原始角色、武器和贴图位于 `../工程/预览渲染工程/assets/4006_科幻世界/PolygonSciFiWorlds/Models/`。不要把生成的重绑模型当作原始素材。

2026-09-06 按用户要求删除了旧重绑模型、v2 动画、旧审核图帧、烘焙工程及旧生成/探测脚本。旧的“下一步提示词”已废弃，后续工作以 v3 说明和 `../../docs/plan/4006原厂骨架动画基线-plan.md` 为准。v3 目前是单角色基线，其他角色需要基于原厂素材重新制作和验证。
