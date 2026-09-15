shader_type canvas_item;

uniform sampler2D reference_texture : hint_default_white, repeat_disable;
// 未开雾仍透出底图：纯黑遮罩会让 256 图小地图看起来像“没有小地图”。
uniform float unexplored_alpha = 0.58;

void fragment()
{
  float revealed = textureLod(reference_texture, UV, 0.0).r;
  COLOR.rgb = vec3(0.0);
  COLOR.a = (1.0 - revealed) * unexplored_alpha;
}
