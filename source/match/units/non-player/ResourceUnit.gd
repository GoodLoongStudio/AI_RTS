extends Area3D

const ResourceDecayAnimation = preload("res://source/match/utils/ResourceDecayAnimation.tscn")

## 矿点周期再生状态（阶段 4）。
##
## 旧语义是"存量归零 → queue_free()"：实体一消失，**没有任何对象承载这个矿点的身份与
## 再生计时**，"过一段时间再长回来"根本无处落地。现在归零只转入 `depleted`（耗尽等待），
## 实体、位置、容量与计时全部保留，由 Match/ResourceRegeneration 按权威模拟毫秒推进恢复。
##
## 状态机：可采(ready) → 耗尽等待(depleted) → 再生可采(ready)。
## 容量 = 本矿点开局存量（`ore_capacity`），恢复只加矿点存量，**绝不直接给玩家账户加钱**；
## 收入仍然必须经过"采集 → 交付"。
var ore_capacity := 0
var depleted := false
## 距离下一次恢复的权威模拟毫秒；仅在 `depleted` 时有意义。
var regen_remaining_ms := 0
## 已完成过几轮恢复。用于结果证据与"同一周期只结算一次"的幂等自检。
var regen_cycles := 0


var radius:
	get:
		return find_child("MovementObstacle").radius
var global_position_yless:
	get:
		return global_position * Vector3(1, 0, 1)


func _ready():
	# 容量在 _ready capture：场景导出的 resource_a/resource_b 此刻已经落好，
	# 而任何采集都还没发生。之后恢复量再大也不会超过这个开局存量。
	ensure_capacity_recorded()
	_refresh_depletion_presentation()


func _enter_tree():
	tree_exiting.connect(_animate_decay)


func _animate_decay():
	var current_parent = get_parent()
	# 整场 Match 卸载时父节点也将销毁，此时不得再延迟创建消散特效。
	if current_parent == null or not current_parent.is_inside_tree():
		return
	var ancestor = current_parent
	while ancestor != null:
		if ancestor.is_queued_for_deletion():
			return
		ancestor = ancestor.get_parent()
	var decay_animation = ResourceDecayAnimation.instantiate()
	decay_animation.global_transform = global_transform
	current_parent.add_child.call_deferred(decay_animation)


## 本矿点当前可采总量（A + B）。统一货币后 B 通常为 0。
func total_ore() -> int:
	return int(get_ore("resource_a")) + int(get_ore("resource_b"))


func get_ore(property_name: String) -> int:
	if property_name in self:
		return int(get(property_name))
	return 0


## 记录容量：以"首次被驱动器看到时的存量"为上限，之后不会再抬高。
func ensure_capacity_recorded() -> void:
	if ore_capacity > 0:
		return
	ore_capacity = maxi(1, total_ore())


## 转入"耗尽等待"。保留实体与身份，只改状态与表现。
func mark_depleted() -> void:
	if depleted:
		return
	depleted = true
	set_meta("ore_depleted", true)
	_refresh_depletion_presentation()


## 恢复可采（再生到账或被外部直接补量时调用）。
func mark_ready() -> void:
	if not depleted:
		return
	depleted = false
	regen_remaining_ms = 0
	remove_meta("ore_depleted")
	_refresh_depletion_presentation()


## 由权威再生驱动器调用：把一次恢复量记进矿点存量，返回**实际**增加的量。
## 超过容量部分直接丢弃（矿量永不超过 capacity），且恢复只进矿点、不进玩家账户。
func apply_regeneration(restore_amount: int) -> int:
	ensure_capacity_recorded()
	if restore_amount <= 0 or total_ore() >= ore_capacity:
		return 0
	# 恢复落到该矿点实际持有的那种资源上（统一货币后通常只有 A）。
	var property_name := "resource_a" if "resource_a" in self else "resource_b"
	var room = ore_capacity - int(get_ore(property_name))
	var added := mini(restore_amount, room)
	if added <= 0:
		return 0
	set(property_name, int(get_ore(property_name)) + added)
	regen_cycles += 1
	mark_ready()
	return added


## 客户端镜像：只接受权威数值与状态，**不在本地推进计时**（两端各自刷矿必然分叉）。
func apply_presentation_ore(report: Array):
	if report.size() < 4:
		return
	# 属性名在子类里声明，基类只能走 set()；setter 自带 max(0,…) 与耗尽/恢复状态迁移。
	if "resource_a" in self:
		set("resource_a", int(report[0]))
	if "resource_b" in self:
		set("resource_b", int(report[1]))
	depleted = bool(int(report[2]))
	regen_remaining_ms = int(report[3])
	_refresh_depletion_presentation()


## 表现层：耗尽 / 稀疏 / 丰富 之间要有清楚区别（提示词 8.1「表现要反映余量」）。
## 采空时保留地表痕迹（缩放压扁而不是隐藏），所以矿点位置仍然可辨识、可选中。
func _refresh_depletion_presentation():
	var geometry := get_node_or_null("Geometry")
	if geometry == null:
		return
	var ratio := 1.0
	if ore_capacity > 0:
		ratio = clampf(float(total_ore()) / float(ore_capacity), 0.0, 1.0)
	# 采空 → 压到 35% 高度（只剩矿脉痕迹）；随余量线性回到 100%。
	var scale_y := 0.35 + 0.65 * ratio
	geometry.scale = Vector3(0.85 + 0.15 * ratio, scale_y, 0.85 + 0.15 * ratio)
