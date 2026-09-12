extends Node

const AdjutantButtonScript = preload("res://source/ui/AdjutantButton.gd")
const OLD_TOKEN := "AIRTS-ADJ-7c91f2x9"
const ENV_VAR := "AI_ADJUTANT_TOKEN"
const CFG_PATH := "user://adjutant_credentials.cfg"

var _failures := 0

func _check(cond, label):
    if cond:
        print("  [PASS] " + str(label))
    else:
        _failures += 1
        print("  [FAIL] " + str(label))

func _remove_cfg():
    if FileAccess.file_exists(CFG_PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG_PATH))

func _write_cfg(token_value):
    var cfg = ConfigFile.new()
    cfg.set_value("adjutant", "token", token_value)
    cfg.save(CFG_PATH)

func _ready():
    var source = FileAccess.open("res://source/ui/AdjutantButton.gd", FileAccess.READ)
    _check(source != null, "AdjutantButton.gd exists")
    if source != null:
        var text = source.get_as_text()
        _check(not text.contains(OLD_TOKEN), "old token absent from client source")
        _check(text.contains("AI_ADJUTANT_TOKEN"), "env var source supported")

    OS.set_environment(ENV_VAR, "")
    _remove_cfg()
    _check(AdjutantButtonScript.load_credential() == "", "missing credential returns empty")

    OS.set_environment(ENV_VAR, "env-token-value")
    _check(AdjutantButtonScript.load_credential() == "env-token-value", "env var wins")

    OS.set_environment(ENV_VAR, "")
    _write_cfg("cfg-token-value")
    _check(AdjutantButtonScript.load_credential() == "cfg-token-value", "user config used")

    OS.set_environment(ENV_VAR, "env-token-value")
    _check(AdjutantButtonScript.load_credential() == "env-token-value", "env beats config")

    OS.set_environment(ENV_VAR, "   ")
    _check(AdjutantButtonScript.load_credential() == "cfg-token-value", "blank env falls back to config")

    var msg403 = AdjutantButtonScript.describe_auth_failure(403)
    _check(msg403.contains("403") and msg403.contains("认证失败"), "403 message explicit")
    _check(AdjutantButtonScript.describe_auth_failure(500).contains("500"), "other codes keep status")

    OS.set_environment(ENV_VAR, "")
    _remove_cfg()
    _check(not FileAccess.file_exists(CFG_PATH), "cleanup done")

    print("Adjutant credential smoke test completed: %d failure(s)" % _failures)
    get_tree().quit(1 if _failures > 0 else 0)
