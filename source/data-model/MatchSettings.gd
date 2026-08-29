extends Resource

enum Visibility { PER_PLAYER, ALL_PLAYERS, FULL }

@export var players: Array[Resource] = []
@export var visibility = Visibility.PER_PLAYER
@export var visible_player = 0
## 本机操控的玩家下标；-1 表示本机没有 Human（专用服）。
@export var local_player_index: int = -1
