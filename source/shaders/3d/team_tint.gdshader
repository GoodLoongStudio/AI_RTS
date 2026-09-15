shader_type spatial;
// 阵营色：保留图集嵌板/灯带/金属，只把阵营色染进灰度通道。
// team_mix=1 时整模变成纯色塑料（实测大湖基地像蓝色蜡模）。
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec4 team_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float team_mix = 0.0;

void fragment() {
	vec4 tex = texture(albedo_texture, UV) * albedo_color;
	float gray = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	vec3 stained = mix(tex.rgb, tex.rgb * team_color.rgb * 1.12, 0.42);
	vec3 wash = mix(stained, gray * team_color.rgb * 1.18, 0.28);
	ALBEDO = mix(tex.rgb, wash, clamp(team_mix, 0.0, 1.0));
	ROUGHNESS = mix(0.38, 0.62, gray);
	SPECULAR = 0.55;
	METALLIC = 0.16 * (1.0 - gray);
}
