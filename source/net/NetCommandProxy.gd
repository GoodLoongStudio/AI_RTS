extends RefCounted
class_name NetCommandProxy

## 客户端命令入口：外形与 UnitCommandGateway 相同，实际只 RPC 到局服。

var _sync: Node
var _player: Node
func _init(sync: Node, player: Node) -> void:
	_sync = sync
	_player = player


func MoveUnits(units, destination, issuer):
	return _sync.forward_command("move", units, destination, null, issuer)


func ForceMoveUnits(units, destination, issuer):
	return _sync.forward_command("force_move", units, destination, null, issuer)


func HaltMovement(units, issuer):
	return _sync.forward_command("halt", units, Vector3.ZERO, null, issuer)


func StopUnits(units, issuer):
	return _sync.forward_command("stop", units, Vector3.ZERO, null, issuer)


func TacticalWithdrawUnits(units, destination, issuer):
	return _sync.forward_command("withdraw", units, destination, null, issuer)


func GroundAttackMoveUnits(units, destination, issuer):
	return _sync.forward_command("ground_attack_move", units, destination, null, issuer)


func AttackUnits(units, target, issuer):
	return _sync.forward_command("attack", units, Vector3.ZERO, target, issuer)


func ForceAttackUnits(units, target, issuer):
	return _sync.forward_command("force_attack", units, Vector3.ZERO, target, issuer)


func ForceAttackGround(units, destination, issuer):
	return _sync.forward_command("force_attack_ground", units, destination, null, issuer)


func EntityAttackMoveUnits(units, target, issuer):
	return _sync.forward_command("entity_attack_move", units, Vector3.ZERO, target, issuer)


func FollowEntityUnits(units, target, issuer):
	return _sync.forward_command("follow", units, Vector3.ZERO, target, issuer)


func ApproachEntityUnits(units, target, issuer):
	return _sync.forward_command("approach", units, Vector3.ZERO, target, issuer)


func GatherResources(units, target, issuer):
	return _sync.forward_command("gather", units, Vector3.ZERO, target, issuer)


func ConstructUnits(units, target, issuer):
	return _sync.forward_command("construct", units, Vector3.ZERO, target, issuer)


func CancelConstruction(site, issuer):
	return _sync.forward_command("cancel_construct", [site], Vector3.ZERO, site, issuer)


func SetEngagementStance(units, stance, issuer):
	# 客户端不再乐观写入姿态：回基地可能因没有己方基地或导航不可用被
	# 服务器拒绝，HUD 必须等权威快照确认，避免显示假状态。
	return _sync.forward_command("set_engagement_stance", units, Vector3.ZERO, null, issuer, str(stance))


func SetFirePolicy(units, policy, issuer):
	return _sync.forward_command("set_fire_policy", units, Vector3.ZERO, null, issuer, str(policy))


func GetEngagementStance(unit):
	if _sync != null and _sync.has_method("get_authoritative_engagement_stance"):
		return _sync.get_authoritative_engagement_stance(unit)
	return "Aggressive"


func GetFirePolicy(unit):
	if _sync != null and _sync.has_method("get_authoritative_fire_policy"):
		return _sync.get_authoritative_fire_policy(unit)
	return "FireAtWill"
