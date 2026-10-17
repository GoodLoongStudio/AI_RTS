extends Node3D

## 炮弹落点一次性爆炸表现（仿 Defilade 命中效果）：
## 橙红火光迸发 + 黑烟升腾，全部粒子一次性爆发，1.8 秒后自毁。
##
## 【2026-10-12 尺寸口径，两次返工后定稿】生成方（CannonShell / Rocket）把本次攻击的
## **权威判定半径**写进 meta `blast_radius_m`（来源 balance `warheads[].radiusMeters`，
## 经 `ProjectileRuntime.GetWarheadRadius`），本场景据此自适应缩放。
##
## 为什么不是"特效铺满判定半径再略大一点"：最大的一档判定半径是 8m，那是 16 米宽的圆，
## 而本特效是 26 颗方块粒子 + 18 颗烟块，铺到 16 米就成了满屏地砖（用户实拍判"过于离谱"）。
## 所以锚点是：**最大档 8m 等于原美术尺寸**，更小的爆炸按比例缩；方块粒子本身只按平方根长，
## 免得单颗火花变成几米大的色块。真要让读者看清 8m 杀伤圈，该补的是地面冲击波 decals，
## 不是把火球放大 —— 那是另一件事。
const BLAST_RADIUS_META := "blast_radius_m"
## 参考档：判定半径 8m（tank_cannon_splash）= 原美术尺寸 scale 1.0。
const RADIUS_REFERENCE_M := 8.0
const MAX_SPREAD_SCALE := 1.0
const MIN_SPREAD_SCALE := 0.45
## 单颗火花的尺寸增长指数：1.0 会让 5m 档的粒子边长跟着涨到几米，看着像地砖。
const PUFF_GROWTH_EXPONENT := 0.5


## 散开范围缩放：判定半径 ÷ 参考档，夹在 [MIN, MAX]。半径 0（直击弹头）保持原尺寸。
static func spread_scale_for(blast_radius: float) -> float:
	if blast_radius <= 0.0:
		return 1.0
	return clampf(blast_radius / RADIUS_REFERENCE_M, MIN_SPREAD_SCALE, MAX_SPREAD_SCALE)


## 单颗火花尺寸缩放：只按散开缩放的平方根长。
static func puff_scale_for(blast_radius: float) -> float:
	return pow(spread_scale_for(blast_radius), PUFF_GROWTH_EXPONENT)


func _ready():
	var blast_radius := float(get_meta(BLAST_RADIUS_META, 0.0))
	if blast_radius > 0.0:
		var spread := spread_scale_for(blast_radius)
		var puff := puff_scale_for(blast_radius)
		scale = Vector3.ONE * spread
		# 节点 scale 只管粒子散开的位置；每颗火花画多大在 process_material 的 scale_min/max 里。
		# ⚠ 这版 ParticleProcessMaterial 的 scale_min / scale_max 是联动的（写 min 会带着 max 走），
		# 连写两次 `*= f` 会被乘两遍（实测 1.4 → 4.9 → 30.1），必须先取原值再分别赋值。
		# 材质按实例 duplicate，绝不改共享资源本体。
		for child in get_children():
			if child is GPUParticles3D and child.process_material is ParticleProcessMaterial:
				var mat: ParticleProcessMaterial = child.process_material.duplicate()
				var base_min: float = mat.scale_min
				var base_max: float = mat.scale_max
				mat.scale_min = base_min * puff
				mat.scale_max = base_max * puff
				child.process_material = mat
	for child in get_children():
		if child is GPUParticles3D:
			child.emitting = true
	get_tree().create_timer(1.8).timeout.connect(queue_free)
