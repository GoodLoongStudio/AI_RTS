extends Node

enum PlayerType {
	NONE = 0,
	HUMAN = 1,
	SIMPLE_CLAIRVOYANT_AI = 2,  # 中等
	AI_EASY = 3,
	AI_HARD = 4,
}


static func is_rule_ai(controller: int) -> bool:
	return (
		controller == PlayerType.SIMPLE_CLAIRVOYANT_AI
		or controller == PlayerType.AI_EASY
		or controller == PlayerType.AI_HARD
	)


static func rule_ai_difficulty(controller: int) -> int:
	# 与 SimpleClairvoyantAI.Difficulty 同序：EASY=0 NORMAL=1 HARD=2
	match controller:
		PlayerType.AI_EASY:
			return 0
		PlayerType.AI_HARD:
			return 2
		_:
			return 1


class Match:
	extends "res://source/match/MatchConstants.gd"

	class Player:
		const RULE_AI_SCENE = preload(
			"res://source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.tscn"
		)
		const CONTROLLER_SCENES = {
			PlayerType.HUMAN: preload("res://source/match/players/human/Human.tscn"),
			PlayerType.SIMPLE_CLAIRVOYANT_AI: RULE_AI_SCENE,
			PlayerType.AI_EASY: RULE_AI_SCENE,
			PlayerType.AI_HARD: RULE_AI_SCENE,
		}


class Player:
	const COLORS = [
		Color("2979ff"),
		Color("ff5252"),
		Color("00e676"),
		Color("d500f9"),
		Color("006400"),
		Color("bdb76b"),
		Color("000080"),
		Color("48d1cc"),
		# TODO: make sure the colors below are visually distinct from the ones above
		Color("ff0000"),
		Color("ffa500"),
		Color("ffff00"),
		Color("00ff00"),
		Color("00fa9a"),
		Color("0000ff"),
		Color("da70d6"),
		Color("d8bfd8"),
		Color("ff00ff"),
		Color("1e90ff"),
		Color("fa8072"),
		Color("2f4f4f"),
	]


# gdlint: ignore=class-variable-name
var OPTIONS_FILE_PATH:
	set(_value):
		pass
	get:
		return (
			"user://options.tres"
			if not FeatureFlags.save_user_files_in_tmp
			else "res://tmp/options.tres"
		)
