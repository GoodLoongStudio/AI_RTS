extends RefCounted
## 电脑玩家的决策节奏（唯一实现）。
##
## 用户 2026-09-15：「一局开 3 个电脑非常卡」→ 批准按**本局电脑玩家人数**给单个 AI 降频。
## 依据：每个 Controller 每拍都会发起十几次世界查询（每个编组各扫一次全图、每个空闲工人一次
## 资源扫描、每次资源交付再查一次经济），而 AI 的每拍开销 ≈ 全场单位数 × 玩家数 ——
## 是"电脑个数"直接放大的，3 个电脑时全场单位数也约为单 AI 局的 3 倍。
##
## 为什么不按帧率自适应：AI 行为必须可复现（对局档案、验收、复现实验都要逐局比对），
## 帧率驱动的降频会让同一局在不同机器/不同画质下跑出不同节奏。
## 1 个电脑（或数不出人数）= 保持原始节奏，行为与从前完全一致。
const SCALE_BY_AI_COUNT := {
	1: 1.0,  # 0.5s（原始节奏）
	2: 1.5,  # 0.5s → 0.75s
	3: 2.0,  # 0.5s → 1.0s
}
## 【2026-09-17 修复确定缺陷】表内没有的电脑数（4 个及以上）原先会 `get(..., 1.0)`
## 回落到**默认节奏** ⇒ 电脑越多反而扫描越频繁，与降频目的相反（方案第 1 节表）。
## 现改为按人数**线性外推**，倍率随电脑数单调不减。
const SCALE_PER_EXTRA_AI := 0.5
const MAX_KEYED_AI_COUNT := 3


## 本局有几个电脑玩家：人类玩家跑的是别的脚本，所以按"脚本相同"计数。
static func ai_count(ai_node: Node) -> int:
	if ai_node == null or not ai_node.is_inside_tree():
		return 1
	var node_script: Script = ai_node.get_script()
	var count := 0
	for player in ai_node.get_tree().get_nodes_in_group("players"):
		if player.get_script() == node_script:
			count += 1
	return maxi(1, count)


## 单个 AI 的决策间隔倍率（≥ 1.0，随电脑数单调不减）。
static func scale(ai_node: Node) -> float:
	var count := ai_count(ai_node)
	if SCALE_BY_AI_COUNT.has(count):
		return float(SCALE_BY_AI_COUNT[count])
	# 4 个及以上：线性外推，绝不回落默认节奏。
	return (
		float(SCALE_BY_AI_COUNT[MAX_KEYED_AI_COUNT])
		+ float(count - MAX_KEYED_AI_COUNT) * SCALE_PER_EXTRA_AI
	)
