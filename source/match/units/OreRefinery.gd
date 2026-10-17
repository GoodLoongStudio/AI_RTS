extends "res://source/match/units/Structure.gd"

## 矿场（2026-09-23 用户口径"专门造矿场指派工人去采矿"，红警2 式）。
##
## 【2026-09-28 红警2 口径】经济单位更名"矿车"（内部 id 仍是 worker），开局不送、
## 车厂生产；**本矿场真实施工完成时赠送一辆**（同 RA2 精炼厂带一台 harvest）。
##
## 行为契约（游戏侧权威，副官不再逐工人下采集令）：
## ① 建成后每隔 claim_interval_s 把**处于经济采集状态或空闲**的工人指派到本矿场
##    （带容量上限）；指派 = 设 meta + 一次"到矿点报到"的移动。采哪颗矿由工人按
##    当前视野自选，满载交给最近的己方完工矿场，不再用服务半径做门槛。
## ② 不抢**改变了任务类别**的工人：移动/施工/交战这类显式订单一律不碰，
##    在册工人被这类订单拿走时立刻释放名额（玩家与军事优先）；
## ③ 矿场没了 → 解除全部指派，工人回退"基地采集"既有行为；
## ④ 指派是软约束：被显式订单打断后不反抗，等下一次空闲再接管，并立刻腾出名额；
## ⑤ 当前视野里没有可采矿点时**一个都不指派**——名额不许空占。服务半径不再参与。
##
## 【②为什么按任务类别而不是"有没有订单"】2026-09-27 实测（fs_diag2，隔离端口段同种子）：
## 计时器与矿都正常，6 个工人全部在 `CollectingResourcesSequentially` 里，
## 旧判据把他们一律视为"有显式订单"，结果矿场在真实对局里一次人都接不到、交付恒为 0。
## 采集类是矿场的本职范围（只改采矿区与交货点，不改任务类别），故纳入可接管；
## 判定与理由的完整证据链见 docs/程序文档/AI副官_建筑无工人建造与矿场散矿_阶段6续_真实对局矿场闭环_2026-09-27.md。

## 真实数值由 BalanceConfigRuntime 从 balance 目录写进来（与 construction_work_per_tick /
## resources_max 同一套口径），不留在脚本里当唯一事实来源。配置可能在本节点 _ready 之后
## 才写入，所以三个 setter 都要能作用到已经跑起来的定时器上。
@export var claim_interval_s := 2.0:
	set(value):
		claim_interval_s = value
		if _claim_timer != null:
			_claim_timer.wait_time = value
## 每座矿场同时指派的工人上限（红警2 一台精炼厂 2~4 个 harvest 的经济节奏）。
@export var worker_capacity := 4
## 遗留导出。玩法不再读取：接管、指派、寻矿、交货都不看它。
## 平衡表里的 serviceRadiusMeters 已从 schema 删除，运行时也不会再写回这个字段。
## 测试仍可把它设成 1 来抓住「有人又把它当门槛」的回归。
@export var service_radius_m := 46.0
## 释放之后多久之内**不再接管同一个工人**（秒）。
## 为什么需要：真实对局里规则中台也在给工人下采集令，两边都会下令时会出现
## "矿场派过去 → 规则令顶掉 → 名额释放 → 立刻又派" 的乒乓
## （fs_verify1 实测：60 秒内接管计数从 6 涨到 25，而 `delivered` 只涨了 2）。
## 提示词 §8.3 明确禁止"反复重下相同采集订单"，冷却把重派频率压到可接受，
## 同时保留"工人真的空下来再接管"的语义。
@export var reclaim_cooldown_s := 20.0
## 判定「这颗矿点工人真的采得到」时，允许站台比矿点自身 carve 净空再远多少米。
## 【2026-09-30 实测表（夹具隔离端口，静态图，XZ 距离）】工人能站到的最近点在
##   - 普通矿点：3.16 / 3.20 / 3.21 / 3.61 m（≈ 自身 carve 净空 3.40 = 0.6 半径 + 2.8 agent）
##   - 被建筑 carve 咬住的矿点：8.04 / 8.21 / 8.66 / 8.85 / 9.00 / 12.94 / 18.80 m
##   - 边界样本：ResourceA 4.05 m（**工人确实采得到**，因为 Recast 体素量化让实际落点更近）
## 取 carve + 2.0 作阈值：把 4.05 这类采得到的留下，把 6.15 以上采不到的排除，两侧都留余量。
const GATHER_REACH_SLACK_M := 2.0
## 连通性复核的末点容差：路径末点距矿点超过它就算"走不到"。
## 【2026-09-30 问题B 收尾】实测存在"在网格上但不连通"的矿点：XZ 离网格 0.00m、clamp 后 Y 也对，
## 移动令**依然同一帧** Unreachable、工人位移 0。map_get_closest_point 判不出这一档。
const CONNECTIVITY_END_TOLERANCE_M := 1.5
## 报到点吸附到导航网格时允许的最大修正距离（米）。超过就说明那一侧不是可走面，保持原站位。
const STAND_SNAP_MAX_M := 4.0
## 指派标记写在工人节点上的 meta 键（值是本矿场节点）。
const ASSIGNMENT_META := "ore_refinery_assignment"
## 冷却到期时刻（引擎毫秒）写在工人身上的 meta 键。
const RECLAIM_COOLDOWN_META := "ore_refinery_reclaim_until_ms"
## 接管断点仪表的打印间隔（次）：claim_interval_s=2 ⇒ 约每 20 秒一行，只在"一个都接不到"时打。
const CLAIM_DIAG_INTERVAL := 10
## 完工赠送的矿车场景（2026-09-28 红警2 口径）。
const FREE_MINER_SCENE := preload("res://source/match/units/Worker.tscn")

var _claim_timer: Timer = null
var _assigned: Array = []
var _claim_ticks := 0
## 完工赠车只发一次（constructed 信号与补路径之间防双发）。
var _free_miner_granted := false
## 【2026-10-11 赠车失败恢复】出生点找不到时旧的唯一出路是等 `constructed` 再发——
## 而那不会再发生，等于永久不赠（提示词 §A2 点名的风险）。这里在 2s 心跳里做
## **有界 + 节流** 的重试；测试/脚本"以完工态直接放置"的路径从不尝试，故不受扰动。
const FREE_MINER_MAX_RETRIES := 8
const FREE_MINER_RETRY_INTERVAL_MS := 4000
var _free_miner_retries := 0
var _free_miner_next_try_ms := 0


func _ready():
	super()
	_claim_timer = Timer.new()
	_claim_timer.wait_time = claim_interval_s
	_claim_timer.timeout.connect(_claim_tick)
	add_child(_claim_timer)
	if has_signal("constructed") and not constructed.is_connected(_on_constructed):
		constructed.connect(_on_constructed)
	if is_constructed():
		# 直接以完工态放置（脚本化对局/测试）：_ready 时就已经就绪。
		_claim_timer.start()
		if _constructed_ms < 0:
			_constructed_ms = Time.get_ticks_msec()


func _on_constructed():
	_claim_timer.start()
	if _constructed_ms < 0:
		_constructed_ms = Time.get_ticks_msec()
	_grant_free_miner()
	# 运营阶段开始的凭据：没有这一行，"矿场没接管工人"就分不清是
	# "计时器根本没起来"还是"起人了但没人合资格"。
	print("[REFINERY] %s 完工，接管计时器已启动（间隔 %.1fs，容量 %d）"
		% [name, claim_interval_s, worker_capacity])


## 【2026-09-28 红警2 口径】矿场**真实施工完成** → 赠送一辆矿车。
## 两个刻意收窄：
## ① 只在权威端发（`is_server()` 或非联机）：客户端镜像里 `constructed` 同样会发出
##    （`present_construction` → `_finish_construction`），不挡的话每端多一辆；
##    权威端生成后由 NetSync 正常镜像给客户端。
## ② 只走 `constructed` 信号路径：测试/脚本"以完工态直接放置"（`_setup_and_spawn_unit`
##    mark=false）不 emit 该信号 ⇒ 不赠车，矿场运营冒烟测试的指定工人账目不受赠车扰动。
func _grant_free_miner():
	if _free_miner_granted:
		return
	if not (NetSession.is_server() or not NetSession.is_networked()):
		return
	var player := get_parent()
	var match_node := find_parent("Match")
	if player == null or match_node == null:
		return
	_free_miner_granted = true
	var miner := FREE_MINER_SCENE.instantiate()
	var navigation_map := RID()
	var occupancy = null
	if match_node.navigation != null:
		navigation_map = match_node.navigation.get_navigation_map_rid_by_domain(
			miner.movement_domain
		)
		if match_node.navigation.has_method("should_skip_runtime_navigation") \
				and match_node.navigation.should_skip_runtime_navigation(match_node.map):
			var map_node = match_node.get_node_or_null("Map")
			if map_node != null and map_node.has_meta("water_occupancy"):
				occupancy = map_node.get_meta("water_occupancy")
	# 【2026-09-29 尺寸口径统一】与 ProductionQueue.try_deploy_authoritative **共用同一套**
	# 世界角点出生点算法（UnitPlacementUtils.production_spawn_spot）：旧实现这里按旧
	# footprint radius + 固定世界 +Z 方向，与生产链路口径不一致（"一个贴脸一个飞出去"）。
	# Start on the working side of the refinery, avoiding a needless route
	# around its own body. The shared search still validates every spawn.
	var exit_direction := Vector3.ZERO
	var ore = _nearest_ore(global_position)
	if ore != null:
		exit_direction = (ore.global_position - global_position) * Vector3(1, 0, 1)
	var placement = Utils.Match.Unit.Placement.production_spawn_spot(
		self, miner, 0.1, navigation_map, get_tree(), 24, occupancy, exit_direction
	)
	if placement == Vector3.INF:
		miner.queue_free()
		_free_miner_granted = false
		_free_miner_retries += 1
		_free_miner_next_try_ms = Time.get_ticks_msec() + FREE_MINER_RETRY_INTERVAL_MS
		if _free_miner_retries >= FREE_MINER_MAX_RETRIES:
			push_error("OreRefinery could not find a safe free-miner spawn point after %d tries: %s"
				% [_free_miner_retries, name])
		else:
			push_warning("OreRefinery free-miner spawn failed (try %d/%d), will retry: %s"
				% [_free_miner_retries, FREE_MINER_MAX_RETRIES, name])
		return
	if occupancy != null and occupancy.has_method("project_ground"):
		placement = occupancy.project_ground(placement)
	MatchSignals.setup_and_spawn_unit.emit(
		miner, Transform3D(Basis.IDENTITY, placement), player
	)
	# 赠车走 GDScript 出生，不经过生产命令，出厂 action 为空。
	# 不在这里点火的话，矿场 2 秒心跳会给它下一条报到移动令。
	miner.call_deferred("request_legacy_start_auto_gather")
	print("[REFINERY] %s 完工赠送矿车 %s" % [name, miner.name])


## 交付点标记：CollectingResourcesSequentially 据此把交货目标从指挥中心扩展到矿场。
func is_drop_off() -> bool:
	return true


func service_radius() -> float:
	return service_radius_m


func assigned_workers() -> Array:
	return _assigned


## 运营结果账（阶段 3 的矿场里程碑与阶段 6 的对局报告都读这里，不看"发过命令"）：
## takeover_count = 累计接管过多少个工人；delivered_* = 实际回本矿场交付的次数与矿量。
var takeover_count := 0
var delivered_count := 0
var delivered_amount := 0
## 完工→首次权威交付的毫秒数（-1 = 还没交付）。玩家关心的是「矿场多久真的开始出矿」，
## 所以以入账时刻为准，不看"发过几条命令"；`_constructed_ms` 是该矿场开始运营的时刻。
var first_delivery_ms := -1
var _constructed_ms := -1


## 由 CollectingResourcesSequentially 在**权威入账成功之后**回调。
func record_delivery(worker, amount: int):
	if amount <= 0:
		return
	if first_delivery_ms < 0 and _constructed_ms >= 0:
		first_delivery_ms = Time.get_ticks_msec() - _constructed_ms
		print("[REFINERY] %s 完工→首次交付 = %.1fs（§6 要的矿场首次产出时间）" % [
			name, first_delivery_ms / 1000.0])
	delivered_count += 1
	delivered_amount += amount
	print("[REFINERY] %s 收到交付 worker=%s amount=%d（累计 %d 次 / %d 矿）" % [
		name, str(worker.name) if worker != null else "?", amount, delivered_count,
		delivered_amount])


func delivery_stats() -> Dictionary:
	return {
		"constructed": is_constructed(),
		"assigned": _assigned.size(),
		"takeovers": takeover_count,
		"delivered_count": delivered_count,
		"delivered_amount": delivered_amount,
		"first_delivery_ms": first_delivery_ms,
		"service_radius_m": service_radius_m,
		"worker_capacity": worker_capacity,
		"has_ore": has_serviceable_ore(),
		# §6 逐局报告要求"每座矿场实际服务的矿点与 Worker 数"。原先只报了有没有矿
		# （`has_ore`），一座矿场管 1 颗和管 5 颗在证据上长得一样。
		"served_nodes": serviced_ore_count(),
	}


## 当前视野内**仍有剩余资源**且采得到的矿点颗数。与 `_nearest_ore` 同一套判据。
func serviced_ore_count() -> int:
	var count := 0
	for resource in get_tree().get_nodes_in_group("resource_units"):
		if _ore_is_serviceable(resource):
			count += 1
	return count


func _exit_tree():
	_release_all()


## 解除全部指派（矿场被卖/被打掉、或半径内矿点全部采空时工人回退基地采集）。
func _release_all():
	for worker in _assigned:
		if is_instance_valid(worker) and worker.has_meta(ASSIGNMENT_META):
			_release_worker(worker)
	_assigned.clear()


## 释放一个名额，并给该工人盖上冷却戳。
## 冷却只在"本矿场主动放手"时打，不打在"工人自己死了/换场"这些路径上。
func _release_worker(worker) -> void:
	worker.remove_meta(ASSIGNMENT_META)
	worker.set_meta(RECLAIM_COOLDOWN_META,
		Time.get_ticks_msec() + int(reclaim_cooldown_s * 1000.0))


## 冷却中 = 刚被释放，短时间内不再重新接管（避免与规则层的采集令互相顶）。
func _in_reclaim_cooldown(worker) -> bool:
	if not worker.has_meta(RECLAIM_COOLDOWN_META):
		return false
	return Time.get_ticks_msec() < int(worker.get_meta(RECLAIM_COOLDOWN_META))


## 满载 = 正在回矿场交付（resource_a/b > 0）。对满载工人的任何指派/召回/重启都会
## 打断返程交付——实测形成死循环：满载回城 → 立刻"指派工人" → 采集 action 重启 →
## 再满载 → 再打断，交付恒 0（R2/R3 真实局取证；副官侧已同步豁免补采）。
func _worker_is_laden(worker) -> bool:
	if worker == null or not is_instance_valid(worker):
		return false
	return int(worker.get("resource_a")) + int(worker.get("resource_b")) > 0


func _claim_tick():
	if not is_inside_tree() or not is_constructed():
		return
	_claim_ticks += 1
	# 【2026-10-11 赠车失败恢复】有界 + 节流重试（只在曾经尝试且失败过之后启动）。
	if (not _free_miner_granted
			and _free_miner_retries > 0 and _free_miner_retries < FREE_MINER_MAX_RETRIES
			and Time.get_ticks_msec() >= _free_miner_next_try_ms):
		_grant_free_miner()
	_assigned = _assigned.filter(func(worker): return is_instance_valid(worker))
	_supervise_assigned()
	# 视野里已经没有可采的矿：先把人全部放回去，别再占名额、也别把人派到没矿的地方。
	if not has_serviceable_ore():
		_release_all()
		return
	if _assigned.size() >= worker_capacity:
		return
	var player := get_parent()
	if player == null:
		return
	var candidates: Array = []
	var diag := {"workers": 0, "held_by_other": 0, "cooldown": 0, "busy": {}}
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit) or unit.get_parent() != player:
			continue
		if str(unit.get("unit_type_id")) != "worker":
			continue
		diag["workers"] += 1
		if unit.has_meta(ASSIGNMENT_META):
			diag["held_by_other"] += 1
			continue
		if _worker_is_laden(unit):
			# 满载矿车正在返程交付：指派会打断它（见 `_worker_is_laden`）。
			diag["laden"] = int(diag.get("laden", 0)) + 1
			continue
		if _in_reclaim_cooldown(unit):
			# 刚被释放过：等冷却过去再说，否则就和规则层的采集令互相顶。
			diag["cooldown"] += 1
			continue
		if not _is_claimable(unit):
			# 断点分布仪表：真实对局里矿场一次人都接不到时，必须能看出**卡在哪一类任务**，
			# 否则只能靠猜——"根本没有人空闲"和"采集令被当成显式订单"是两种完全不同的改法。
			var action = unit.get("action")
			var action_name := "<null>"
			if action != null and action.get_script() != null:
				action_name = str(action.get_script().resource_path).get_file()
			diag["busy"][action_name] = int(diag["busy"].get(action_name, 0)) + 1
			continue
		candidates.append(unit)
	if candidates.is_empty() and diag["workers"] > 0 and _claim_ticks % CLAIM_DIAG_INTERVAL == 1:
		print("[REFINERY-CLAIM] %s 在册=%d/%d 无可接管工人：工人=%d 已被占用=%d 冷却=%d 忙=%s" % [
			name, _assigned.size(), worker_capacity,
			diag["workers"], diag["held_by_other"], diag["cooldown"], str(diag["busy"])])
	elif not candidates.is_empty() and _nearest_ore_stand(candidates[0]) == null \
			and _claim_ticks % CLAIM_DIAG_INTERVAL == 1:
		# 有合资格候选人、名额也没满，却还没派上——只会是 `_assign` 里找不到报到点。
		# 这一类不打印的话，"矿场抢不到人"就永远只有"没人空闲"这一种解释（fs_ref10：
		# assigned 从 2 掉回 0 之后 130 秒不再接管，两种可能的改法完全不同）。
		print("[REFINERY-CLAIM] %s 在册=%d/%d 候选人=%d 但报到点为空：stand=%s 视野内可采矿=%s" % [
			name, _assigned.size(), worker_capacity, candidates.size(),
			str(_nearest_ore_stand(candidates[0])), str(has_serviceable_ore())])
	# 近的优先：先把离家近的工人拉过来，别让基地的工人长途奔袭。
	candidates.sort_custom(func(a, b):
		return (a.global_position.distance_squared_to(global_position)
			< b.global_position.distance_squared_to(global_position)))
	for worker in candidates:
		if _assigned.size() >= worker_capacity:
			return
		_assign(worker)


## 当前视野内是否还有**有剩余资源**且采得到的矿点。矿点身份由 ResourceUnit 持有。
func has_serviceable_ore() -> bool:
	return _nearest_ore(global_position) != null




## 已指派工人的监护：到了矿场附近若闲住，就恢复自动采集（移动订单结束后
## AutoGathering 不会自己回来，必须有人重新挂上）。
func _supervise_assigned():
	var still_ours: Array = []
	for worker in _assigned:
		if not is_instance_valid(worker):
			continue
		# meta 已被别的矿场或显式命令改走 → 这个名额不再属于我们。
		if not worker.has_meta(ASSIGNMENT_META) or worker.get_meta(ASSIGNMENT_META) != self:
			_log_release(worker, "meta_taken_over")
			continue
		if _worker_is_laden(worker):
			# 满载：留册但不 move、不释放、不重启采集——让它把这一趟交付走完。
			still_ours.append(worker)
			continue
		var action: Node = worker.get("action")
		var action_name := _action_script_name(worker)
		if action_name in GATHERING_ACTIONS:
			# 采集类留在册。不再用服务半径把「采得远」当成被调走。
			# 规则中台的采集令也会建权威订单，不能靠「有订单」释放，否则接管和采集令互相顶、交付归零。
			# 玩家的移动/攻击/停止走下面的 Moving、空闲或非经济分支，不在这里抢人。
			# 到矿点后开始顺序采集 = 我们要的状态，必须**留在册**。
			# 旧实现只认 AutoGatheringResources，于是工人一进入 CollectingResourcesSequentially
			# 就被当成"被显式订单拿走"而释放名额（fs_ref10 实测：assigned 从 2 掉回 0，
			# 之后 190 秒再没接管过任何人，交付 0）。
			still_ours.append(worker)
			continue
		if action_name == "Moving.gd":
			# 矿场自己的报到移动走 `request_legacy_move`，**不建权威订单**；玩家/副官的
			# 显式移动令会建一条。据此区分"正在走来矿场"与"被显式订单调走"——
			# 比对目的地坐标可靠得多（目的地会被导航吸附，误差可达数米，
			# 用目的地判会每轮误释放、反复重派，工人一步都走不到矿点）。
			if _has_authoritative_order(worker):
				_log_release(worker, "moving_with_authoritative_order")
				_release_worker(worker)
			else:
				still_ours.append(worker)
			continue
		if action == null:
			still_ours.append(worker)
			# 停止、或仍挂着未结束的权威订单时，不要把自动采集挂回去。
			if _player_is_holding(worker) or _has_authoritative_order(worker):
				continue
			if worker.has_method("request_legacy_start_auto_gather"):
				worker.request_legacy_start_auto_gather()
			continue
		# 其它（施工/交战等**改变了任务类别**的订单）：玩家与军事优先，立刻腾出名额。
		# 【2026-09-27 修一处自埋的隐性 bug】上一版把局部 `action` 变量删掉后，
		# 这里的 `action` 解析到矿场自己继承来的 `action` 属性（建筑永远是 null），
		# 于是这个分支永远走不到、非经济任务工人被一直挂在册。
		# 现在显式取 `worker.get("action")`。
		_log_release(worker, "non_economic_task:" + action_name)
		_release_worker(worker)
	_assigned = still_ours


## 释放原因留痕（诊断，不参与判定）。
## 为什么必须有：fs_precheck 里 `assigned` 在 0/2/0/3/0 之间跳，两种可能
## （规则层抢人 vs 工人半路阵亡）的修法完全不同，光看计数猜不出来。
func _log_release(worker, reason: String) -> void:
	if _claim_ticks % CLAIM_DIAG_INTERVAL > 2:
		return
	print("[REFINERY-RELEASE] %s 释放 %s 原因=%s" % [name, str(worker.name), reason])


func _player_is_holding(worker) -> bool:
	return worker != null and worker.has_meta("player_hold_auto")


## 工人身上是否挂着权威订单（显式命令的标志）。取不到网关时按"没有订单"处理：
## 宁可多留一个指派，也不要误释放后反复重派把工人钉在原地。
func _has_authoritative_order(worker) -> bool:
	var owner = worker.get_parent()
	if owner == null:
		return false
	var gateway = owner.get_node_or_null("UnitCommandGateway")
	if gateway == null or not gateway.has_method("GetActiveOrderState"):
		return false
	return not str(gateway.GetActiveOrderState(worker)).is_empty()


## 可指派判据。
##
## 【2026-09-27 实测改判】原来的判据只认 `action == null` 与 `AutoGatheringResources.gd`。
## 隔离端口段重跑同一粒种子（fs_diag2）拿到的是：
##     [REFINERY] Unit_104 完工，接管计时器已启动（间隔 2.0s，容量 4，服务半径 30.0m）
##     [REFINERY-CLAIM] Unit_104 在册=0/4 无可接管工人：工人=6 已被占用=0
##                      忙={ "CollectingResourcesSequentially.gd": 6 }
## 也就是**计时器是好的、矿是有的、人全在采**——但"正在采"被当成"不可接管"，
## 于是矿场在真实对局里永远一个人都接不到（提示词 §D 预判的那一条成立）。
##
## 采集类（自动采集 / 顺序采集 / 范围内采集）就是矿场的本职范围：
## 矿场只是把他的采矿区改到本矿场服务半径内、交货点改到本矿场，任务类别没变。
## 而移动、施工、交战这类**改变了任务类别**的订单一律不碰；在册工人一旦被这类订单拿走，
## `_supervise_assigned()` 立刻释放名额（玩家与军事优先）。
const GATHERING_ACTIONS := [
	"AutoGatheringResources.gd",
	"CollectingResourcesSequentially.gd",
	"CollectingResourcesWhileInRange.gd",
]

## 接管只认空闲车。正在采集的车不改成报到移动令。
## GATHERING_ACTIONS 仍用于在册工人是否留名额，不用于接管。
const CLAIMABLE_ACTIONS: Array[String] = []


func _action_script_name(unit) -> String:
	var action = unit.get("action")
	if action == null or action.get_script() == null:
		return ""
	return str(action.get_script().resource_path).get_file()


func _is_claimable(unit) -> bool:
	if _player_is_holding(unit):
		return false
	var action = unit.get("action")
	if action == null:
		return true
	var action_name := _action_script_name(unit)
	if action_name.is_empty():
		return true
	return action_name in CLAIMABLE_ACTIONS


## 指派一名工人；**只有真的找到可采的矿点才算占一个名额**（旧实现无矿也占，
## 4 个槽位被空挂，还把这些工人的交货点改指到远处矿场）。
func _assign(worker):
	var target: Variant = _nearest_ore_stand(worker)
	if target == null:
		return
	worker.set_meta(ASSIGNMENT_META, self)
	_assigned.append(worker)
	# 累计接管数：`takeover_count` 早先是声明了却从没自增，于是仪表里的
	# `takeovers` 永远是 0，§6 要的"首次矿场接管 Worker 时间"这条指标也永远不落账
	# （fs_ref10 实测：assigned=2 而 takeovers=0）。接管事实以这里为准。
	takeover_count += 1
	# "到矿场报到"：派到**服务半径内最近的可用矿点**旁边（站在矿点外侧一点），
	# 不是矿场旁边——贴着建筑避让圈站会被每帧推回、原地抖（2026-09-23 实测），
	# 而矿点外侧是稳定落点；到了以后 AutoGathering 自然会采这块矿。
	# 【2026-09-30 第 11 轮 结论】"让矿场指派对采集目标有约束力"试过两条路，**都被 A/B 证伪**：
	#   ① 全局覆盖（被接管就采矿场指定的矿）→ ore-refinery 失败 3 → **9** 条（连"矿点总存量
	#      必须被真实采掉"都红，即全局采集被破坏）；
	#   ② 指派时改绑采集任务（request_legacy_gather）→ 3 → **5** 条，新增回归
	#      "显式订单必须立刻让矿场放手（玩家接管优先）"。
	# 结论：本系统里"工人自主就近采集"是**承重设计**（玩家接管优先、经济吞吐都依赖它），
	# 矿场只能"移动工人到站位"，不能替它决定采哪颗矿。要改必须由设计层先定语义。
	# 证据：第 11 轮只读诊断显示矿场要 @Area3D@394(d=17.2)、工人却选 ResourceA2(d=10.6)。
	# 【2026-09-30 问题B】报到只是「把人送到矿点站位」的一次移动令：采哪颗矿仍由工人自选。
	# 取证结论（含为什么不能改采集目标、为什么不能换 MovingToUnit）见
	# docs/问题B_矿场指派语义_结论.md §2/§3。
	if worker.has_method("request_legacy_move"):
		worker.request_legacy_move(target)
	print("[REFINERY] %s 指派工人 %s 到矿场采矿（%d/%d） ore=%s" % [
		name, worker.name, _assigned.size(), worker_capacity, target])


## 本建筑所在域的导航地图；逻辑地形图（不烘 Recast）返回无效 RID，调用方须按
## 「旧口径」处理（不引入新判据）。
func _navigation_map() -> RID:
	var match_node := find_parent("Match")
	if match_node == null or match_node.navigation == null:
		return RID()
	if match_node.navigation.has_method("should_skip_runtime_navigation") \
			and match_node.navigation.should_skip_runtime_navigation(match_node.get_node_or_null("Map")):
		return RID()
	return match_node.navigation.get_navigation_map_rid_by_domain(movement_domain)


## 点到导航网格的**平面**距离：> 贴合阈值就等于「工人站不到能采的地方」。
## 只比 XZ：Recast 烘出来的面比真实地表高约 0.8m，带上 Y 会把「就在网格上」读成 0.8m。
func _off_mesh_xz(point: Vector3, nav_map: RID) -> float:
	if not nav_map.is_valid():
		return 0.0
	var closest := NavigationServer3D.map_get_closest_point(nav_map, point)
	if not closest.is_finite():
		return 0.0
	return Vector2(closest.x - point.x, closest.z - point.z).length()


## 服务半径内距 from 最近的**可服务**矿点；没有可用矿返回 null。
##
## 【2026-09-30 问题B · rule①】「有剩余资源」不等于「工人采得到」：矿点一旦落在建筑的
## carve 洞里（实测：目标矿点离矿场 11.10m < carve 12.6m），工人能站到的最近点远在 6.10m 外，
## 而贴合阈值只有 3.9m ⇒ 这颗矿**物理上永远采不空**。这种矿点不许参与
## `has_serviceable_ore` / `_nearest_ore_stand`，否则矿场会拿它的名义去抢工人、占名额，
## 工人却被派到一个走不到的站位（实测移动令同一帧以 Unreachable 结束，工人一步没动），
## 紧接着又被自己的自选采集接管 —— 这正是「矿场指派无约束力」的真身。
func is_ore_reachable(resource) -> bool:
	if resource == null or not is_instance_valid(resource):
		return false
	var nav_map := _navigation_map()
	if not nav_map.is_valid():
		# 逻辑地形图（不烘 Recast）：保持旧口径，不引入导航网格判据。
		return true
	var reach := _off_mesh_xz(resource.global_position, nav_map)
	var clearance: float = Utils.Match.Unit.Movement.carve_clearance_of(resource)
	return reach <= clearance + GATHER_REACH_SLACK_M


## 该工人**从自己站的地方**能否真正走到至少一颗可服务矿点。
## 判据：map_get_path 非空且末点距矿点 <= CONNECTIVITY_END_TOLERANCE_M（只比 XZ）。
## 不可达就不申领 —— 派出去也是同一帧 Unreachable、工人一步没走（实测），
## 反倒占住名额、把工人从自选采集里拽出来。
func _worker_can_reach_serviceable_ore(worker) -> bool:
	var ore = _nearest_ore(worker.global_position)
	if ore == null:
		return false
	var nav_map := _navigation_map()
	if not nav_map.is_valid():
		# 逻辑地形图（不烘 Recast）：保持旧口径。
		return true
	var path := NavigationServer3D.map_get_path(nav_map, worker.global_position, ore.global_position, true)
	if path.is_empty():
		return false
	var end: Vector3 = path[path.size() - 1]
	return Vector2(end.x - ore.global_position.x, end.z - ore.global_position.z).length() 		<= CONNECTIVITY_END_TOLERANCE_M


func _ore_is_serviceable(resource) -> bool:
	if not is_instance_valid(resource):
		return false
	var a = resource.get("resource_a")
	var b = resource.get("resource_b")
	if not ((a != null and int(a) > 0) or (b != null and int(b) > 0)):
		return false
	if not is_ore_reachable(resource):
		return false
	return _player_can_see_ore(resource)


func _player_can_see_ore(resource) -> bool:
	var player = get_parent()
	var match_node = find_parent("Match")
	if match_node == null:
		return true
	var fog = match_node.get_node_or_null("FogOfWar")
	if fog == null or not fog.has_method("player_can_see"):
		return true
	return bool(fog.player_can_see(player, resource.global_position, resource))


func _nearest_ore(from: Vector3) -> Variant:
	var best = null
	var best_distance := INF
	for resource in get_tree().get_nodes_in_group("resource_units"):
		if not _ore_is_serviceable(resource):
			continue
		var distance: float = (resource.global_position * Vector3(1, 0, 1)).distance_to(
			from * Vector3(1, 0, 1))
		if distance >= best_distance:
			continue
		best_distance = distance
		best = resource
	return best


## 最近的可用矿点 + 站在它外侧的偏移点；没有可用矿返回 null。
func _nearest_ore_stand(worker) -> Variant:
	var best = _nearest_ore(global_position)
	if best == null:
		return null
	# 站在**矿点背向矿场的一侧**：朝矿场那一侧是建筑避让圈，站过去会被每帧
	# 推回（2026-09-23 实测工人在圈界原地抖）；背向一侧既贴近可采又稳定。
	var away: Vector3 = (best.global_position - global_position) * Vector3(1, 0, 1)
	if away.length() < 0.1:
		away = (worker.global_position - best.global_position) * Vector3(1, 0, 1)
	if away.length() < 0.1:
		away = Vector3.FORWARD
	var direction := away.normalized()
	var worker_radius: float = float(worker.get("radius"))
	var stand_off: float = float(best.get("radius")) + worker_radius + 0.4
	var stand: Vector3 = best.global_position + direction * stand_off
	# 报到点还必须**走出矿场自己的避让圈**：只按矿点半径算时，矿点离矿场比矿场碰撞体
	# 更近会让工人永远走不进去、被每帧推回原地抖，实测表现为"指派了、也在 Moving，
	# 但一百多秒都到不了矿点"。
	# 【2026-09-29 口径统一】避让圈按**碰撞体**半径算（与 navmesh 挖洞同源），
	# 不再用 footprint `radius`（统一尺寸后矿场 9.8m，会把报到点推到 12.4m 外、
	# 甚至推出可走区 —— 用户实报"矿车过不去、FollowEntity 被拒"）。
	var body := _structure_body_radius()
	var clearance := body + worker_radius + 0.6
	var pushes := 0
	while stand.distance_squared_to(global_position) < clearance * clearance and pushes < 32:
		stand += direction * 0.5
		pushes += 1
	stand.y = best.global_position.y
	# 【2026-10-12 建筑卡单位】逻辑地形（生成图＝玩家实际玩的图）根本不烘导航网格：
	# 下面那次吸附在未激活的网格上只会拿到零向量哨兵，等于没做。而"这里能不能站"
	# 在这类图上由 `GeneratedTerrain.is_ground_blocked` 说了算，所以必须按它复验一遍：
	# 否则报到点可能落在另一栋楼的足迹里或水里，工人被每帧推回、原地抖到超时
	# （2026-09-23「工人在圈界原地抖」、09-30「一百多秒到不了矿点」实测的都是这件事，
	# 只是当时只有导航网格那一版救得了）。
	var terrain = Utils.Match.Unit.Movement.logic_terrain_of(self)
	if terrain != null:
		var untangled := 0
		while bool(terrain.is_ground_blocked(stand)) and untangled < 24:
			stand += direction * 0.5
			untangled += 1
		if bool(terrain.is_ground_blocked(stand)):
			# 沿背向推满 12m 仍不可走就别派：工人走到那儿也贴不上矿点，
			# 只会把整条经济链卡在"已指派但到不了"上。
			return null
		stand.y = best.global_position.y
		return stand
	# 【2026-09-30 问题B】报到点必须落在**可走面**上。矿点贴地图边/贴建筑时，旧口径把站台
	# 沿「背向矿场」推出去，会推到导航网格之外（实测 (50.1,0,8)：离最近可走点 6.80m），
	# 于是移动令同一帧以 Unreachable 结束、工人一步没走就被自己的自选采集接管 ——
	# 「矿场指派无约束力」有一半是这个。这里按 XZ 吸附到网格最近点（与 Movement 的
	# clamp 同源，但那里只在 5m 内且 owner 有效时才救，救不了这种 6.8m 的偏差）。
	var nav_map := _navigation_map()
	if nav_map.is_valid():
		var closest := NavigationServer3D.map_get_closest_point(nav_map, stand)
		# 只接受**小修正**：吸附点若离原站位太远（实测出现过 8.7m 的错误吸附），说明那一侧
		# 根本不是可走面，此时保持原站位（工人会自己走到最近的可走处），
		# 绝不能把报到点搬到离矿点 9m 外——那样工人到了也贴不上、还会就近改采别的矿。
		if closest.is_finite() and closest.distance_to(stand) <= STAND_SNAP_MAX_M:
			stand = Vector3(closest.x, stand.y, closest.z)
	return stand


## 本建筑的权威 world-space 避让半径。Unit.radius/MovementObstacle.radius 已经是
## 按场景 root scale 换算后的世界值；不能直接读 vertices 的局部坐标，否则 root=3
## 的矿场会被当成 1.4m，矿车报到点就会落进建筑模型。
func _structure_body_radius() -> float:
	var obstacle: Node = get_node_or_null("MovementObstacle")
	if obstacle == null:
		return float(radius)
	var configured = obstacle.get("radius")
	return float(configured) if configured != null else float(radius)
