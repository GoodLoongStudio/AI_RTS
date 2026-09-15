shader_type spatial;

// Bridge / catwalk steel.  Deliberately neutral dark grey so the six G4 river
// crossings separate from the warm desert terrain instead of reading as rust.
uniform sampler2D base_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : filter_linear_mipmap, repeat_enable;
uniform vec3 steel_tint = vec3(0.34, 0.34, 0.34);
uniform float grime_amount = 0.75;
uniform float dust_amount = 0.18;
varying vec3 p;
varying vec3 wn;
varying vec2 uv0;

void vertex() {
 p=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
 wn=normalize(MODEL_NORMAL_MATRIX*NORMAL);
 uv0=UV;
}
void fragment() {
 vec3 base=texture(base_tex,uv0).rgb;
 float luma=dot(base,vec3(.299,.587,.114));
 // Keep the authored PolygonSciFiWorlds panel pattern visible at close range;
 // only apply a restrained neutral tint instead of collapsing it to luminance.
 vec3 steel=vec3(luma) * steel_tint * 1.9;
 vec3 weights=pow(abs(wn),vec3(4.0));
 weights/=max(dot(weights,vec3(1.0)),.001);
 float broad=textureLod(rock_tex,p.zy*.11,3.0).r*weights.x
  +textureLod(rock_tex,p.xz*.11,3.0).r*weights.y+textureLod(rock_tex,p.xy*.11,3.0).r*weights.z;
 float fine=texture(rock_tex,p.xz*1.7+p.y*.25).r;
 float grime=smoothstep(.34,.74,broad*.8+fine*.2);
 vec3 col=steel*(0.90-grime*.34*grime_amount);
 float dust=smoothstep(.55,.98,wn.y)*(1.0-smoothstep(.12,.40,broad))*dust_amount;
 col=mix(col,vec3(.46,.45,.42),dust);
 float rail=0.0;
 float stripe=step(.5,fract((p.z+p.x)*.40));
 vec3 warning=mix(vec3(.075,.078,.072),vec3(.40,.32,.13),stripe);
 col=mix(col,warning,rail*.16);
 ALBEDO=col;
 METALLIC=.48*(1.0-grime*.5);
 ROUGHNESS=mix(.46,.74,grime*grime_amount+dust);
 NORMAL_MAP=texture(rock_normal,uv0*1.8).rgb;
 NORMAL_MAP_DEPTH=.025;
}
