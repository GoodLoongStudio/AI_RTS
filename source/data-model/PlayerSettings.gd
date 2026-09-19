extends Resource

@export var color = Color.BLUE
@export var controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
@export var spawn_index_offset = 0
## 规则 AI 难度：0 简单 / 1 中等 / 2 困难。人类与空槽忽略。
@export var difficulty := 1
