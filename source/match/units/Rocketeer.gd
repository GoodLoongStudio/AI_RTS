extends "res://source/match/units/Unit.gd"

const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")

## 炮兵：步兵骨架 + 火箭筒（Hand_R 骨骼挂点换枪，隐藏 GLB 内嵌步枪）。
const WEAPON_SCENE := "res://assets/models/polygon-scifi/SM_Wep_Launcher_01.fbx"
const GLB_ROOT := "Infantry_native_v3"
const BAKED_GUN := "Rifle"
const HAND_BONE := "Hand_R"


func _ready():
	await super()
	action_changed.connect(_on_action_changed)
	action = WaitingForTargets.new()
	_attach_hand_weapon()


## 把 GLB 内嵌的步枪藏掉，换成 火箭筒（挂在 Hand_R 骨骼上随动画刚性随动）。
func _attach_hand_weapon():
	var glb_root = find_child(GLB_ROOT, true, false)
	if glb_root == null:
		return
	var baked_gun = glb_root.find_child(BAKED_GUN, true, false)
	if baked_gun != null:
		baked_gun.visible = false
	var skeleton = glb_root.find_child("InfantrySkeleton", true, false)
	if skeleton == null or not skeleton is Skeleton3D:
		return
	var attach := BoneAttachment3D.new()
	attach.name = "HandWeaponAttachment"
	skeleton.add_child(attach)
	attach.bone_name = HAND_BONE
	var weapon_scene := load(WEAPON_SCENE)
	if weapon_scene == null:
		return
	var weapon = weapon_scene.instantiate()
	attach.add_child(weapon)


func _on_action_changed(new_action):
	if new_action == null:
		action = WaitingForTargets.new()
