shader_type spatial;
// blend_mix + near-shore alpha fade: the water plane intersects the sloped bank
// along the 2 m render grid, which draws a sawtooth waterline. Fading the sheet
// out over its first ~2.5 m reveals the land shader's continuous wet band and
// hides the staircase entirely.
render_mode cull_disabled, blend_mix, depth_draw_opaque;

uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float showcase_world_scale = 1.0;
uniform sampler2D sand_normal : filter_linear_mipmap, repeat_enable;
uniform bool lake_mode = false;
uniform bool terrain_depth = false;
// Parchment-palette companion: turquoise-teal water against the warm desert,
// deepening towards a blue-green centre instead of the old fluorescent green.
uniform vec3 shallow_col : source_color = vec3(0.26, 0.54, 0.51);
uniform vec3 deep_col : source_color = vec3(0.045, 0.21, 0.28);
// ---- 共享模式开关（与 showcase_land 同机制）----
// review 渲染器把「到岸距离」写进水面顶点的 UV.x（mask_from_tex=0）；
// 游戏内水面是一组游程盒片，没有可控 UV，改为按世界坐标采样
// terrain_masks.png 的 G 通道（= 岸距，米，v/600+0.5 编码），
// 于是同一个 shader 在两条通路上得到同一个 edge。
uniform float mask_from_tex = 0.0;
uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform float mask_world_size = 2048.0;
varying vec3 p;
varying vec3 wp;

void vertex() {
 wp = (MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
 p = wp / showcase_world_scale;
}
void fragment() {
 float edge;
 if (mask_from_tex > 0.5) {
  // terrain_masks 的 G 通道是【带符号】岸距（语义米，水内为负），
  // 取负即水面侧的"到岸距离/浅滩"，与 review 侧顶点 UV.x 同量纲。
  edge = max(0.0, -(texture(mask_tex, wp.xz / mask_world_size).g - 0.5) * 600.0);
 } else {
  edge = max(0.0, UV.x);
 }
 vec2 uv1=p.xz*0.006+vec2(0.17,-0.09);
 vec2 uv2=p.xz*0.023+vec2(.41,.13);
 float broad=texture(rock_tex,uv1).r;
 float ripple=texture(rock_tex,uv2).r;
 float depth;
 if (terrain_depth) { depth=smoothstep(0.0,7.5,UV.y); }
 else { depth=smoothstep(0.0,15.0+4.0*broad,edge); }
 // Fast tonal change near the shore, slow in the middle: real water reads by
 // its shelf, not by a linear ramp.
 depth=pow(clamp(depth,0.0,1.0),0.72);
 vec3 col=mix(shallow_col,deep_col,depth);
 // Large-scale tonal drift plus fine ripple shimmer (stronger in the shallows
 // where the bed is close).
 col+=(broad-.5)*vec3(.03,.045,.04);
 col+=(ripple-.5)*vec3(.05,.06,.055)*(1.0-depth*0.55);
 // Shore band: white foam thread on the waterline, darker wet rim just inside.
 float foam=1.0-smoothstep(0.0,6.0,edge);
 float rim=1.0-smoothstep(0.0,1.6,edge);
 col=mix(col,vec3(.66,.77,.74),foam*0.32*(0.45+0.55*ripple));
 col=mix(col,col*0.5,rim*0.75);
 // Deep water leans on the sky tint, as it would by reflection.
 col=mix(col,vec3(.55,.70,.78),depth*0.22);
 ALBEDO=col;
 // Near-shore alpha fade hides the rasterized waterline (see render_mode note).
 ALPHA=smoothstep(0.0,2.5,edge);
 // Two layered wave normals, the second finer and offset so the surface never
 // looks like one stretched texture.
 vec3 n1=texture(sand_normal,uv1).rgb;
 vec3 n2=texture(sand_normal,uv2*1.7+vec2(.3,.7)).rgb;
 NORMAL_MAP=normalize(mix(n1,n2,0.45)*0.5+0.5);
 NORMAL_MAP_DEPTH=.40;
 // The single biggest realism lever: a tight specular lobe so the sun paints
 // actual highlights instead of a matte green card.
 ROUGHNESS=mix(0.28,0.46,depth);
 SPECULAR=0.62;
}
