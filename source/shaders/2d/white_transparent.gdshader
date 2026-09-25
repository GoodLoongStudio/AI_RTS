shader_type canvas_item;

uniform sampler2D reference_texture : hint_default_white, repeat_disable;
// 未探索区不显示地形（2026-09-24 用户要求："小地图战争迷雾区域应该是不能显示
// 地形的，只有探索过才能显示"）。原 0.58 会让 256 生成图的小地图把整张图的
// 台地/河道轮廓透出来，等于把战争迷雾里的敌情白送玩家。现为 1.0：未探索纯黑，
// 已探索才见地形——红警/星际类小地图的标准行为。
uniform float unexplored_alpha = 1.0;

void fragment()
{
  float revealed = textureLod(reference_texture, UV, 0.0).r;
  COLOR.rgb = vec3(0.0);
  COLOR.a = (1.0 - revealed) * unexplored_alpha;
}
