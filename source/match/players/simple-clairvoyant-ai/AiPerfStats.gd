## 性能插桩计时桶（测量专用）。
## 各控制器用 preload 常量引用本脚本（不经全局类名缓存，避免新文件类名注册延迟）。
## 环境变量 AIRTS_AI_PERF_STATS=1 时才记录；未开启时 enabled() 为 false，调用方零开销。
## 桶累加 [调用次数, 总微秒, 最大单次微秒]；快照只读导出，不清零。
## 父桶（arbitration）包含子桶（economy / provision），禁止把它们相加。
## hitch 只保留 >=100ms 的有限条，避免逐帧 JSON。

extends RefCounted

static var _buckets: Dictionary = {}
static var _hitches: Array = []
static var _initialized := false
static var _enabled := false

const _HITCH_US := 100000
const _HITCH_KEEP := 48


static func enabled() -> bool:
	if not _initialized:
		_enabled = OS.get_environment("AIRTS_AI_PERF_STATS") == "1"
		_initialized = true
	return _enabled


## 记录一个桶的耗时（微秒）。父桶与子桶分开记，调用方标明包含关系。
static func add(bucket: String, microseconds: int) -> void:
	if not _buckets.has(bucket):
		_buckets[bucket] = [0, 0, 0]
	var slot: Array = _buckets[bucket]
	slot[0] += 1
	slot[1] += microseconds
	if microseconds > int(slot[2]):
		slot[2] = microseconds
	if microseconds >= _HITCH_US and _hitches.size() < _HITCH_KEEP:
		var hitch := {
			"bucket": bucket,
			"us": microseconds,
			"process_frame": Engine.get_process_frames(),
			"physics_frame": Engine.get_physics_frames(),
			"ticks_usec": Time.get_ticks_usec(),
		}
		_hitches.append(hitch)
		print("[AI-PERF] hitch bucket=%s us=%d process_frame=%d physics_frame=%d" % [
			bucket, microseconds, hitch["process_frame"], hitch["physics_frame"]])


## 导出当前累计值（不修改计数）。只含桶，不含 hitch 列表。
static func snapshot() -> Dictionary:
	var result := {}
	for bucket in _buckets:
		var slot: Array = _buckets[bucket]
		var calls := int(slot[0])
		var total := int(slot[1])
		result[bucket] = {
			"calls": calls,
			"total_us": total,
			"per_call_us": (total / calls) if calls > 0 else 0,
			"max_us": int(slot[2]) if slot.size() > 2 else 0,
		}
	return result


## >=100ms 的有限 hitch 记录。与 snapshot 分开，避免破坏只认桶字段的读取方。
static func hitch_log() -> Array:
	return _hitches.duplicate(true)


static func reset() -> void:
	_buckets.clear()
	_hitches.clear()
