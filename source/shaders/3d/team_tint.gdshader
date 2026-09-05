shader_type spatial;
// 阵营色着色（2026-09-05）：图集/贴图纹理先去饱和，再乘阵营色并保留少量原细节。
// 纯相乘会被 Synty 高饱和金黄纹理吞掉阵营色（实测），去饱和后各阵营一目了然。
uniform sampler2D albedo_texture : source_color;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec4 team_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float team_mix = 0.0;
void fragment() {
	vec4 tex = texture(albedo_texture, UV) * albedo_color;
	float gray = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	vec3 team = gray * team_color.rgb * 1.4;
	ALBEDO = mix(tex.rgb, team, team_mix);
	ROUGHNESS = 0.8;
}
