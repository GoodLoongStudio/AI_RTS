extends RefCounted

## 指挥官身份（2026-09-10）：绑定本机设备 ID，同一台电脑永远用同一个指挥官身份与昵称。
##
## 规则：
##   1) 设备 ID 优先用 OS.get_unique_id()（桌面平台的硬件/系统级稳定 ID），
##      不可用时退回首次运行生成并持久化的随机 ID；
##   2) 默认昵称由设备 ID 派生（指挥官-XXX），因此同一台电脑每次进入昵称一致；
##   3) 玩家改过昵称则持久化该昵称，后续进入沿用（不再随机）；
##   4) 自动化/测试可用命令行覆盖：--player-device=<id> / --player-name=<名称>
##      （覆盖值只作用于本次进程，不写入存档，避免污染真实身份）。
##
## 存储：user://player_identity.cfg（与 camera.cfg / audio.cfg 同一 user:// 约定）。

const CONFIG_PATH := "user://player_identity.cfg"
const SECTION := "identity"
const NAME_PREFIX := "指挥官-"
const NAME_MAX := 16
const DEVICE_MAX := 64

static var _cache: Dictionary = {}


## 本机设备 ID（安装后稳定不变）。
static func device_id() -> String:
	return str(_load().get("device_id", ""))


## 本机指挥官昵称（默认由设备 ID 派生，可被玩家自定义覆盖）。
static func display_name() -> String:
	return str(_load().get("name", ""))


## 由设备 ID 派生稳定默认昵称：同一台电脑 → 同一个 3 位码。
static func default_name_for(device: String) -> String:
	if device.is_empty():
		return NAME_PREFIX + "000"
	var digest := device.md5_text()
	return "%s%03d" % [NAME_PREFIX, int(digest.substr(0, 8).hex_to_int() % 1000)]


## 记住玩家自定义昵称（空字符串视为放弃覆盖，回到默认昵称）。
static func remember_name(value: String) -> String:
	var trimmed := value.strip_edges().substr(0, NAME_MAX)
	var cache := _load()
	var device := str(cache.get("device_id", ""))
	cache["name"] = (default_name_for(device)
		if trimmed.is_empty() or trimmed == default_name_for(device) else trimmed)
	cache["dirty"] = true
	_cache = cache
	if not bool(cache.get("override", false)):
		_persist()
	return str(cache["name"])


## 测试/自动化：覆盖本进程的设备 ID 与昵称（不落盘）。
static func force_identity(device: String, player_name: String = "") -> void:
	var key := _sanitize_device(device)
	if key.is_empty():
		return
	_cache = {
		"device_id": key,
		"name": player_name.strip_edges().substr(0, NAME_MAX) if not player_name.strip_edges().is_empty() else default_name_for(key),
		"override": true,
		"dirty": false,
	}


static func describe() -> Dictionary:
	var cache := _load()
	return {
		"device_id": str(cache.get("device_id", "")),
		"name": str(cache.get("name", "")),
		"override": bool(cache.get("override", false)),
	}


static func _load() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var config := ConfigFile.new()
	var stored_device := ""
	var stored_name := ""
	if config.load(CONFIG_PATH) == OK:
		stored_device = str(config.get_value(SECTION, "device_id", ""))
		stored_name = str(config.get_value(SECTION, "name", ""))
	var device := _sanitize_device(stored_device)
	if device.is_empty():
		device = _device_id_from_os()
	if device.is_empty():
		device = "uuid-" + _random_token()
	var player_name := stored_name.strip_edges().substr(0, NAME_MAX)
	if player_name.is_empty():
		player_name = default_name_for(device)
	_cache = {"device_id": device, "name": player_name, "override": false,
		"dirty": stored_device != device or stored_name != player_name}
	if bool(_cache["dirty"]):
		_persist()
	_apply_cli_overrides()
	return _cache


static func _apply_cli_overrides() -> void:
	var args := OS.get_cmdline_user_args()
	var device := ""
	var player_name := ""
	for i in range(args.size()):
		var arg := str(args[i])
		if arg.begins_with("--player-device="):
			device = arg.substr("--player-device=".length())
		elif arg.begins_with("--player-name="):
			player_name = arg.substr("--player-name=".length())
	if device.is_empty() and player_name.is_empty():
		return
	var key := _sanitize_device(device) if not device.is_empty() else str(_cache.get("device_id", ""))
	_cache = {
		"device_id": key,
		"name": player_name.strip_edges().substr(0, NAME_MAX) if not player_name.is_empty() else default_name_for(key),
		"override": true,
		"dirty": false,
	}


static func _device_id_from_os() -> String:
	# 桌面平台返回硬件/系统级稳定 ID；某些平台可能为空或全 0 → 视为不可用。
	var unique := ""
	if OS.has_method("get_unique_id"):
		unique = str(OS.get_unique_id()).strip_edges()
	if unique.is_empty() or unique.replace("0", "").is_empty():
		return ""
	return "dev-" + unique.md5_text().substr(0, 16)


static func _sanitize_device(value: String) -> String:
	return value.strip_edges().substr(0, DEVICE_MAX)


static func _random_token() -> String:
	var bytes := PackedByteArray()
	for _i in range(16):
		bytes.append(randi() % 256)
	return bytes.hex_encode()


static func _persist() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION, "device_id", str(_cache.get("device_id", "")))
	config.set_value(SECTION, "name", str(_cache.get("name", "")))
	config.save(CONFIG_PATH)
	_cache["dirty"] = false
