shader_type spatial;
// Synty 图集把「阵营漆」画成金黄块。整图乘阵营色会被黄色吞掉（蓝队看起来像黄车）。
// 只替换暖黄区域，灰板/金属/青色灯带保持原样。
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec4 team_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float team_mix = 0.0;

void fragment() {
	vec4 tex = texture(albedo_texture, UV) * albedo_color;
	float gray = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	float warmth = tex.r - tex.b;
	float sat = max(tex.r, max(tex.g, tex.b)) - min(tex.r, min(tex.g, tex.b));
	float cyan = smoothstep(0.04, 0.22, tex.b - tex.r);
	float yellow_mask = smoothstep(0.10, 0.28, warmth) * smoothstep(0.12, 0.36, sat) * (1.0 - cyan);
	vec3 painted = mix(vec3(gray), team_color.rgb, 0.90) * (0.42 + gray * 0.78);
	float paint = yellow_mask * clamp(team_mix * 1.65, 0.0, 1.0);
	ALBEDO = mix(tex.rgb, painted, paint);
	ROUGHNESS = mix(0.38, 0.62, gray);
	SPECULAR = 0.55;
	METALLIC = 0.16 * (1.0 - gray);
}
