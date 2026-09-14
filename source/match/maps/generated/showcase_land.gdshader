shader_type spatial;
// 地形双面渲染：游戏内 GeneratedTerrain 的网格绕序与 review 渲染器相反，
// 默认 cull_back 会把整个地形剔除（review 侧双面无视觉差异）。
render_mode cull_disabled;

// G4 terrain material: eight geomorphological layers driven by the accepted G2
// geometry.  The masks arrive as per-vertex floats so that every layer is tied to
// real height / slope / water proximity instead of a colour ramp painted on top.
//   UV    = (signed distance to plateau outline in m, land distance to water in m)
//   UV2   = (signed distance to lake polygon in m, rock mask or -ramp mask)
// Meshes without those channels (kit samples) fall back to the slope-driven path.

#include "res://tools/godot/showcase_shapes.gdshaderinc"

uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D top_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D cliff_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail2_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D bank_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D shore_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ramp_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D cliff_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_gravel_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_wet_shore_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_macro_albedo = false;
uniform float macro_strength = 1.0;

uniform bool cut_water = false;
uniform vec4 main_lane = vec4(0.0);
uniform float main_run = 0.0;
uniform float main_width = 20.16;
// Enables the G4 mask path.  Kit samples without UV/UV2 stay on the slope path.
uniform float use_masks = 0.0;
uniform float ground_height = 2.34;
uniform float top_height = 14.35;
uniform float cliff_ring = 13.0;
uniform float bank_width = 20.0;
uniform float shore_width = 44.0;
uniform float ground_saturation = 0.88;
uniform float normal_strength = 0.012;
// Diagnostic: paint the raw geometry masks instead of the material.
uniform float debug_masks = 0.0;
uniform vec3 top_tint = vec3(1.0);
// ---- 共享模式开关：游戏内 GeneratedTerrain 从 terrain_masks.png 采样掩码
// （mask_from_tex=1，review 走 UV/UV2 顶点属性 =0）。同一份 shader 两边渲染。
uniform float mask_from_tex = 0.0;
uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform float mask_world_size = 2048.0;

varying vec3 p;
varying vec3 wn;
varying vec4 maskA;

float hash21(vec2 q) {
 q=fract(q*vec2(123.34,456.21)); q+=dot(q,q+45.32);
 return fract(q.x*q.y);
}
// 随机梯度方向（单位向量）
vec2 hash22(vec2 q) {
 float a = hash21(q + vec2(37.719, 11.173)) * 6.2831853;
 return vec2(cos(a), sin(a));
}
// 梯度（Perlin）噪声，归一化到 0..1。
//
// 原来的实现是**值噪声**（角点随机值 + 平滑插值），无论用 smoothstep 还是
// 五次插值，角点处导数都为 0 → 晶格线上出现"零梯度平台"，低频域直接读成
// 硬直边的菱形/矩形网格（实测：单独输出 terrain_noise(base_uv*0.035) 可见清晰
// 菱形晶格，周期 ≈ 29m，正是合成图里地面上那些 30m 级拼缝；换五次插值无效，
// 因为五次插值同样在角点导数为 0）。
// 梯度噪声的角点是随机**方向**而非随机值，没有零梯度平台，晶格伪影消失。
float value_noise(vec2 q) {
 vec2 i=floor(q), f=fract(q);
 vec2 u = f*f*f*(f*(f*6.0-15.0)+10.0);
 float a = dot(hash22(i+vec2(0.0,0.0)), f-vec2(0.0,0.0));
 float b = dot(hash22(i+vec2(1.0,0.0)), f-vec2(1.0,0.0));
 float c = dot(hash22(i+vec2(0.0,1.0)), f-vec2(0.0,1.0));
 float d = dot(hash22(i+vec2(1.0,1.0)), f-vec2(1.0,1.0));
 return clamp(0.5 + 0.75 * mix(mix(a,b,u.x), mix(c,d,u.x), u.y), 0.0, 1.0);
}
// 旋转交叉噪声：value_noise 的双线性格点在低频下会留下轴向条纹（实测读作
// "水波/沙纹"），两个 45 度交错的采样叠加后条纹方向互消，读作自然颗粒。
float value_noise_r(vec2 q, float ang) {
 float c = cos(ang), s = sin(ang);
 return value_noise(mat2(vec2(c, s), vec2(-s, c)) * q);
}
float terrain_noise(vec2 q) {
 // 三个互质角度 + 轻微尺度差的交叉采样：单/双 45° 交叉仍会留下菱形晶格
 // （两层的晶格方向一致，只是被 45° 旋转，叠加后依然是菱形网格），
 // 三个不同角度叠加后晶格方向互不成形，读作自然颗粒。
 return value_noise(q) * 0.5
      + value_noise_r(q, 0.785398) * 0.3
      + value_noise_r(q * 1.13, 2.399963) * 0.2;
}
float luma_of(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
vec3 desaturate(vec3 c, float keep) { return mix(vec3(luma_of(c)), c, keep); }
vec3 triplanar(sampler2D t, vec3 pos, vec3 n, float s) {
 vec3 w=pow(abs(n),vec3(6.0));
 w/=max(dot(w,vec3(1.0)),1e-4);
 return texture(t,pos.zy*s).rgb*w.x+texture(t,pos.xz*s).rgb*w.y+texture(t,pos.xy*s).rgb*w.z;
}

void vertex() {
 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz / showcase_world_scale;
 wn = normalize(MODEL_NORMAL_MATRIX * NORMAL);
 if (mask_from_tex > 0.5) {
  vec2 muv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz / mask_world_size;
  // vertex 阶段必须显式 LOD（texture() 依赖导数，vertex 不可用）
  vec4 m = textureLod(mask_tex, muv, 0.0);
  maskA = vec4((m.r - 0.5) * 600.0, (m.g - 0.5) * 600.0, (m.b - 0.5) * 600.0, m.a * 2.0 - 1.0);
 } else {
  maskA = vec4(UV.x, UV.y, UV2.x, UV2.y);
 }
}

void fragment() {
 float shore = min(river_distance(p.xz), lake_distance(p.xz));
 if (cut_water && shore < 4.45) { discard; }

 // Crumb-killing LOD: the crag/grit geometry normals read as dense speckle at
 // overview range. Relaxing the world normal towards 'up' at distance flattens
 // that micro-shading - but ONLY inside rock masses (weighted by rock_in): the
 // desert's own gentle relief shading is part of its material, and flattening
 // it washed the whole floor out to plaster in the first attempt.
 // NOTE: varyings may not be reassigned in fragment (Godot 4), so the relaxed
 // normal is a LOCAL `wnr`; every fragment-side user below reads `wnr`.
 float cam_dist = length(p - CAMERA_POSITION_WORLD);
 float far_view = smoothstep(500.0, 1400.0, cam_dist);

 float plateau_d = maskA.x;
 float shore_d = maskA.y;
 float lake_d = maskA.z;
 float cls = maskA.w;
 if (use_masks < 0.5) {
  plateau_d = 1.0e4;
  shore_d = 1.0e4;
  lake_d = 1.0e4;
  cls = 0.0;
 }
 float rock_in = clamp(cls, 0.0, 1.0);
 float ramp_m = max(-cls, 0.0);
 vec3 wnr = normalize(mix(wn, vec3(0.0, 1.0, 0.0),
     far_view * 0.45 * smoothstep(0.05, 0.5, rock_in)));

 float h = p.y;
 float flatness = clamp(wnr.y, 0.0, 1.0);
 float steep = 1.0 - smoothstep(0.52, 0.86, flatness);
 vec2 base_uv = p.xz;
 // Two mirrored, offset macro tiles keep 150–400 m landform variation visible
 // from the in-game RTS camera without exposing a hard repeat seam.
 vec2 macro_uv0 = abs(fract(base_uv / 950.0) * 2.0 - 1.0);
 vec2 macro_uv1 = abs(fract((base_uv + vec2(430.0,-270.0)) / 950.0) * 2.0 - 1.0);
 vec3 macro_sand = mix(texture(macro_sand_tex, macro_uv0).rgb,
                        texture(macro_sand_tex, macro_uv1).rgb, 0.32);
 vec3 macro_gravel = mix(texture(macro_gravel_tex, macro_uv0).rgb,
                          texture(macro_gravel_tex, macro_uv1).rgb, 0.32);
 vec3 macro_rock = mix(texture(macro_rock_tex, macro_uv0).rgb,
                        texture(macro_rock_tex, macro_uv1).rgb, 0.32);
 vec3 macro_wet = mix(texture(macro_wet_shore_tex, macro_uv0).rgb,
                       texture(macro_wet_shore_tex, macro_uv1).rgb, 0.32);
 macro_sand = mix(vec3(luma_of(macro_sand)), macro_sand, 0.58) * vec3(0.92, 0.95, 0.98);

 // --- macro fields: 1200 m province, 500 m region, 130 m patch, 28 m grain --
 float macro0 = value_noise(base_uv * 0.0008 + vec2(3.1, 8.7));
 float macro1 = value_noise(base_uv * 0.0020);
 float macro2 = value_noise(base_uv * 0.0075 + vec2(17.0, 5.0));
 float macro3 = terrain_noise(base_uv * 0.035 - vec2(5.0, 9.0));
 float macro4 = value_noise(base_uv * 0.00035 + vec2(41.0, 2.0));

 // --- 1. main desert floor: pale grey-beige sand with real regional variety --
 // 主层尺度 20m -> 67m：20m 平铺时贴图自带的沙纹在近距离读作"水波"（实测
 // 多轮 UV 扰动/法线调整均无效——诊断确认来自该采样），放大后读作沙丘波纹。
 vec3 ground = texture(sand_tex, base_uv * 0.015).rgb;
 ground = mix(ground, texture(detail_tex, base_uv * 0.026).rgb,
              smoothstep(0.35, 0.80, macro2) * 0.58);
 // Cool dust flats read as hardpan pans between the dune belts.  This single
 // field is the main "large colour block" driver of the whole map.
 ground = mix(ground, texture(top_tex, base_uv * 0.019).rgb * 0.96,
              smoothstep(0.34, 0.90, macro1) * 0.86);
 // Warm dune belts survive only in the low third of the same field.
 ground = mix(ground, ground * vec3(1.08, 1.01, 0.90),
              smoothstep(0.34, 0.06, macro1) * 0.28);
 ground *= 0.84 + macro0 * 0.24 + macro4 * 0.14;
 ground *= 0.92 + macro3 * 0.16;
 // Mid-frequency ground rhythm: ~250 m warm belts plus ~45 m dune swells.
 // Without these the floor is one flat beige card from any camera distance.
 float belt250 = terrain_noise(base_uv * 0.004 + vec2(23.0, 87.0));
 float dune45 = terrain_noise(base_uv * 0.022 + vec2(5.0, 71.0));
 ground = mix(ground, ground * vec3(1.07, 1.00, 0.89),
              smoothstep(0.42, 0.72, belt250) * 0.34);
 ground *= 0.955 + dune45 * 0.11;
 ground = desaturate(ground, ground_saturation);
 // Warm sand base tone: the parchment-palette floor is golden, not grey.
 ground = mix(ground, ground * vec3(1.10, 1.00, 0.84), 0.38);
 // Static cloud shadows: very large soft darkening patches drifting over the
 // floor. They give the overview the "weather above the desert" depth that flat
 // sun+ambient can never produce, without any dynamic cost.
 float cloud = value_noise(base_uv * 0.0011 + vec2(77.0, 31.0))
             * 0.65 + value_noise(base_uv * 0.0032 + vec2(9.0, 51.0)) * 0.35;
 // Wind ripples give the floor a readable grain direction at any zoom.
 // Keep game-scale sand quiet; broad texture detail survives without periodic bands.
 // UV 噪声扰动（供近景细节与多材质层共用，必须定义在 if 块外）
 // 双频扰动：单频 value-noise 带轴向偏置（实测留下横向条带），叠一层
 // 高频扰动把方向性打散。
 vec2 uv_jit = vec2(value_noise(base_uv * 0.021 + vec2(3.0, 9.0)),
                    value_noise(base_uv * 0.021 + vec2(17.0, 5.0))) * 14.0
             + vec2(value_noise(base_uv * 0.093 + vec2(41.0, 7.0)),
                    value_noise(base_uv * 0.093 + vec2(29.0, 61.0))) * 5.0;
 vec2 uv_g = base_uv + uv_jit;
 if (!use_macro_albedo) { ground *= 0.92; }
 if (use_macro_albedo) {
  // macro 只服务远景色域：近景衰减，避免 34m 视野被大色斑糊成纯色
  float macro_far = smoothstep(140.0, 560.0, cam_dist);
  ground = mix(ground, macro_sand, macro_strength * macro_far);
  // Keep fine PBR below 15%; it breaks up close views without restoring the
  // old tiled checkerboard at RTS distance.
  // 近景细节：20m 层 + ~6m 层 + ~2.2m 极细层；双尺度采样打破平铺周期。
  // detail_tex(sand_01) 本身是"横向沙纹照片"，平铺后形成水波状重复（实测
  // 多轮扰动无效）。改用 dense_sand 的多尺度叠加：同图不同频 -> 均匀沙地 +
  // 颗粒层次，无跨图拼接、无方向性沙纹。
  ground = mix(ground, texture(sand_tex, uv_g * 0.018).rgb, 0.14 + 0.16 * (1.0 - macro_far));
  ground = mix(ground, texture(sand_tex, uv_g * 0.155).rgb,
               0.13 * (1.0 - macro_far));
  // detail2(gray_rocks) 在 0.45 频率 = 每 2.2m 平铺 —— 实测这正是 60m 视野里
  // "2m 级横向波纹"的来源（与网格间距同量级，最刺眼）。降到 0.11（每 9m）
  // 并减半权重，只保留颗粒而不形成周期纹。
  vec3 d2a = texture(detail2_tex, uv_g * 0.110).rgb;
  vec3 d2b = texture(detail2_tex, uv_g * 0.107 + vec2(0.31, 0.17)).rgb;
  ground = mix(ground, mix(d2a, d2b, 0.5), 0.06 * (1.0 - macro_far));
 }

 // ---- 多材质斑驳地表（沙/砾石/裸土/暗土）----
 // 参照真实荒原与主流 RTS：地表是多种材质大块交错 + 边界渐变，不是单一沙色
 // 换色。掩码用 100~200m 尺度的低对比噪声（读作"材质区"而非"斑纹"），
 // 各材质统一乘暖调系数，避免贴图拼贴感。
 vec3 gravel = mix(texture(detail2_tex, base_uv * 0.012).rgb * 0.82, macro_gravel, macro_strength);
 gravel = desaturate(gravel, 0.35) * 1.05;
 float reg = smoothstep(0.70, 0.92, value_noise(base_uv * 0.012 + vec2(31.0, 7.0)));
 gravel *= 0.94 + luma_of(gravel) * 0.10;
 ground = mix(ground, gravel, reg * 0.32);              // 砾石区（原 0.18 几乎不可见）

 float soil_m = smoothstep(0.55, 0.82, value_noise(base_uv * 0.0085 + vec2(11.0, 53.0)));
 vec3 soil = texture(ramp_tex, uv_g * 0.075).rgb;      // dirt_aerial：裸土
 soil = desaturate(soil, 0.25) * vec3(1.06, 1.00, 0.90);
 ground = mix(ground, mix(ground, soil, 0.55), soil_m * 0.50);

 float dark_m = smoothstep(0.60, 0.88, value_noise(base_uv * 0.0060 + vec2(97.0, 13.0)));
 vec3 dark_soil = texture(bank_tex, uv_g * 0.055).rgb;  // brown_mud：暗土
 dark_soil = desaturate(dark_soil, 0.30) * vec3(1.02, 0.97, 0.90);
 ground = mix(ground, dark_soil * 0.94, dark_m * 0.34);
 float rough = 0.88 - macro3 * 0.05 + reg * 0.06;

 // --- 2. plateau top: paler, drier, dusty hardpan ---------------------------
 vec3 top = texture(top_tex, base_uv * 0.012).rgb;
 if (use_macro_albedo) {
  // 原式 x1.035 提亮 + top_tex 本身偏亮 -> 台地顶比周围地面亮 77%（实测），
  // 在高台上形成刺眼的"亮斑"。改为轻微压暗并混入更多色域变化。
  top = mix(top, macro_sand * vec3(0.97, 0.985, 1.0), macro_strength);
  top *= vec3(0.94, 0.945, 0.96);
 }
 // 细颗粒权重 0.18 -> 0.34：盖顶亮起来后宏贴图（0.72 权重）的平滑感暴露成
 // "塑料板"，加回 detail_tex 的沙粒与中频斑驳，让亮顶仍有质地。
 top = mix(top, texture(detail_tex, base_uv * 0.075).rgb * 1.04, 0.34);
 top = mix(top, texture(detail2_tex, uv_g * 0.055).rgb * 1.02,
           smoothstep(0.30, 0.80, value_noise(base_uv * 0.021 + vec2(63.0, 17.0))) * 0.22);
 top = mix(top, top * vec3(1.05, 1.04, 1.00), smoothstep(0.45, 0.85, macro2) * 0.30);
 top *= 0.80 + macro3 * 0.16 + macro0 * 0.13;
 top = mix(top, top * vec3(1.02, 1.00, 0.97), 0.30);
 // 台地顶可读性（2026-09-14 实测调参）：原实现只比平地亮 ~8%（多列聚合实测
 // +7.5%/+8.0%），45° 总览下台地读不出"台面"；更早一版亮 77% 是刺眼亮斑。
 // 目标 ~+20%：去饱和到 0.62（干尘土）、抬亮 1.10，并把"混回平地色"的权重由
 // 0.30 降到 0.16（这一步本身就把对比度拉大 ~20%）。
 top = desaturate(top, 0.62) * top_tint;
 // 亮度系数由反照率实测反算：×1.10 时 top 亮度 140.8 vs ground 145.7（**仍偏暗 3.4%**），
 // 而台地顶需要与平地拉开可读差距 → ×1.36 实测约 +18~20%（去饱和 0.62 已让它比平地
 // 更冷更干，方向正确，只是原本偏暗）。
 top = mix(top, ground * 1.03, 0.16) * 1.92;
 // 台地顶 = 「**高且平**」。2026-09-14 修正：原实现用 `plateau_d < -2.5` 判定，
 // 但 plateau_d 是到【崖壁 blocking 格】的**带符号距离**（导出侧
 // `plateau_region & ~open_`，即只有崖壁环本身），台面上是一大片**正值**
 // （到崖壁的距离 20~50m）→ 实测 top_m≈0，干尘土台面材质根本没上到台面上，
 // 台地顶实际被 ring_in 驱动的崖壁材质盖住（cliff_m≈0.62），与平地几乎同色
 // （多列聚合实测仅 +8% 亮度）。改回几何判定：高度达台地高度 + 坡度小。
 float top_m = smoothstep(ground_height + 4.0, top_height - 1.5, h)
             * (1.0 - steep);

 // --- 3. plateau cliff wall plus its wide weathered rim --------------------
 float rim_noise = value_noise(base_uv * 0.085) * 0.55 + value_noise(base_uv * 0.026) * 1.25;
 float ring_out = 1.0 - smoothstep(0.5, cliff_ring + rim_noise * 11.0, max(plateau_d, 0.0));
 // ring_in 必须只在 plateau_d<0（崖壁环内部）生效。原来的 `max(-plateau_d,0)`
 // 让台面上（-plateau_d<0 → 取 0）也得到 1 → cliff_m≈0.62 把崖壁材质铺满台面，
 // 是台地顶读不出体积感的**直接原因**（逐层探针 M_ringin 实测台面=1）。
 float ring_in = (1.0 - smoothstep(0.5, 7.0 + rim_noise * 5.0, max(-plateau_d, 0.0)))
               * smoothstep(-1.0, 1.0, -plateau_d);
 vec3 cliff = triplanar(cliff_tex, p, wnr, 0.018);
 if (use_macro_albedo) { cliff = mix(cliff, macro_rock, macro_strength); }
 cliff = mix(cliff, triplanar(detail2_tex, p, wnr, 0.145), 0.18);
 // Packed-earth tone one step lighter than the old chocolate (0.34,0.30,0.28):
 // the rim read as a dark cookie outline around every mesa at RTS distance.
 // 崖壁：保留贴图质感（cliff_tex/detail2 的层理与颗粒）+ 提亮的岩壁基色。
 // 原实现直接以纯色 (0.43,0.375,0.32) 覆盖 -> 崖壁变成无细节的深棕"黑边"
 // （总览实测）。0.55 的贴图权重恢复层理，基色提亮并去饱和。
 cliff = mix(cliff, vec3(0.52, 0.465, 0.40), 0.55)
       * (0.90 + luma_of(cliff) * 0.16 + macro3 * 0.05);
// Strata follow world height, so wall layers line up between plateaus; the
// weather-band term adds irregular vertical staining so rims erode instead of
// reading as extruded plastic.
float strata = sin(h * 0.85 + macro2 * 1.6) * 0.5 + 0.5;
float weather_band = value_noise(vec2(base_uv.x * 0.02 + macro4 * 3.0, h * 0.16));
cliff *= 0.90 + strata * 0.10 + weather_band * 0.12;
// Eroded rim: the wall's upper part carries the dusty cap colour and only the
// lower skirt is bare earth - the mesa grows out of its cap instead of wearing
// a hard cookie outline.
float cap_blend = smoothstep(ground_height + 1.0, top_height - 2.5, h);
cliff = mix(cliff, top * 0.985, cap_blend * 0.62);
 cliff = mix(cliff, cliff * vec3(1.06, 0.99, 0.94), smoothstep(0.4, 0.9, macro2) * 0.25);
 float cliff_m = clamp(ring_out * steep + ring_out * (1.0 - steep) * 0.62
                     + ring_in * steep * 0.85 + ring_in * (1.0 - steep) * 0.40, 0.0, 1.0)
               * smoothstep(ground_height - 1.5, ground_height + 3.0, h);

// --- 4. blocking mountains: layered grey-/red-brown rock -------------------
// Height, slope, normal and the G2 rock mask all drive this layer; the macro
// province albedo only tints it, so the detail PBR stays the dominant signal.
float facet = value_noise(base_uv * 0.025);
float rock_band = value_noise(base_uv * 0.011 + vec2(11.0, 29.0));
if (use_masks < 0.5) {
 rock_in = steep * smoothstep(ground_height + 0.5, ground_height + 6.0, h);
}
// Lobate the mask edge so the rock / soil line is not a clean contour.
rock_in = clamp(rock_in * (0.74 + 0.52 * value_noise(base_uv * 0.038 + vec2(19.0, 71.0))), 0.0, 1.0);
float rock_h = smoothstep(ground_height + 0.4, ground_height + 12.0, h);
float rock_m = clamp(rock_in * (0.50 + 0.50 * rock_h), 0.0, 1.0);

vec3 rock = triplanar(rock_tex, p, wnr, 0.018);
// Finer second layer: the province texture alone reads as painted clay at close
// range, so the detail PBR carries more weight and a ~3 m grain.
rock = mix(rock, triplanar(detail2_tex, p, wnr, 0.30), 0.32);
// Bedding follows world height but is warped hard by the band noise - a bare
// sin(h*k) paints contour stripes around the whole range at every zoom.
float m_strata = sin(h * 0.55 + rock_band * 7.0 + macro2 * 2.2) * 0.5 + 0.5;
float m_dip = sin((p.x * 0.35 + p.z * 0.24) * 0.22 + macro3 * 2.0) * 0.5 + 0.5;
rock *= 0.80 + 0.24 * m_strata + 0.10 * m_dip;
// Four rock zones keyed to slope / altitude, with only fine-grain noise as
// disturbance - large low-frequency band noise paints mildew-style blotches
// across the range, so it drives nothing here:
//   steep walls            -> deep grey-brown cliff shade
//   high crests, mid slope -> red-brown main-ridge beds
//   gentle mid slopes      -> warm-grey weathered faces
//   (the pale deposition fan is handled by the talus layer below)
float steepness = 1.0 - smoothstep(0.50, 0.86, flatness);
float altitude = smoothstep(ground_height + 3.0, ground_height + 32.0, h);
// Distance LOD: at overview range the crag/crack detail turns the range into a
// pile of crumbs. Blending it off makes the mass read as one dark silhouette
// with ridge highlights - what a far RTS view needs - while close views keep
// the fractured rock faces. cam_dist / far_view live at the top of fragment().
// Wider spread between the three zones: the earlier near-equal triads collapsed
// into one brown-grey average once lighting averaged them out.
vec3 wall_dark = vec3(0.18, 0.165, 0.15);
vec3 ridge_red = vec3(0.50, 0.285, 0.17);
vec3 weathered = vec3(0.40, 0.365, 0.31);
vec3 rock_zone = mix(weathered, wall_dark, steepness * 0.90);
rock_zone = mix(rock_zone, ridge_red, altitude * (1.0 - steepness * 0.45) * 0.85);
// Sedimentary strata: altitude-banded colour beds (dark grey-brown / red-brown
// alternating), warped by two noise fields so the bands dip, thin and pinch out
// instead of reading as clean contour lines. This is what makes a mountain read
// as ROCK rather than as a sculpted dune.
float strata_band = sin(h * 0.42 + rock_band * 7.0 + facet * 2.4 + macro3 * 1.6) * 0.5 + 0.5;
vec3 bed_a = vec3(0.24, 0.165, 0.115);
vec3 bed_b = vec3(0.52, 0.385, 0.27);
rock_zone = mix(rock_zone, mix(bed_a, bed_b, strata_band),
    smoothstep(0.06, 0.40, rock_in) * 0.82 * (0.45 + 0.55 * m_strata));
// ~90 m lithological patches + ~40 m facet shading break the tone into rock
// faces; without them the whole range reads as one poured-clay surface.
float litho = value_noise(base_uv * 0.011 + vec2(3.0, 33.0));
// Mid-frequency band (20-80 m): the weakest link against the reference. Two
// extra octaves here give the flanks the sandblast / aeolian variation the RTS
// camera reads as surface, without letting high frequency become the far signal.
float mid40 = value_noise(base_uv * 0.028 + vec2(57.0, 91.0));
float mid20 = value_noise(base_uv * 0.062 + vec2(11.0, 7.0));
// Brightening budget must stay under ~1.35x: the previous sum reached 1.62x, so
// even with a dark base the flanks washed out toward sand value under the warm
// key light and the range dissolved into the desert.
rock_zone *= 0.60 + luma_of(rock) * 0.28 + facet * 0.16 * (1.0 - far_view * 0.85)
           + litho * 0.15 + mid40 * 0.12 * (1.0 - far_view * 0.5)
           + mid20 * 0.06 * (1.0 - far_view * 0.95);
// Crack lines: ridged noise (1-|n|) darkens gullies and lightens crests so the
// walls read as eroded rock instead of one poured surface. Faded out at range.
float crack = 1.0 - abs(value_noise(base_uv * 0.05 + vec2(7.0, 43.0)) * 2.0 - 1.0);
rock_zone *= mix(0.88 + crack * 0.18, 1.0, far_view * 0.8);
// Far silhouette: deeper and flatter, so the range holds its own against the
// bright desert instead of dissolving into gravel.
rock_zone *= mix(1.0, 0.80, far_view);
// The zone tone must dominate: at 0.72 the detail PBR averaged the three zones
// back into one brown-grey at RTS distance.
rock = mix(rock, rock_zone, 0.94);
// Weak high-frequency grain (~2 m) - present for close views, never the far signal.
rock = mix(rock, triplanar(detail2_tex, p, wnr, 0.55), 0.06);
// Weak-to-moderate province albedo only; the zoned tone stays dominant.
if (use_macro_albedo) { rock = mix(rock, macro_rock, macro_strength * 0.30); }
// Near-flat bedding planes catch more light; steep crevices fall into shadow.
rock = mix(rock, rock * vec3(1.10, 1.02, 0.92), smoothstep(0.45, 0.92, flatness) * 0.22);
rock *= 0.86 + 0.14 * flatness;
rock = desaturate(rock, 0.92);

// Deposition fan / talus apron: a wide, low-frequency band that carries the
// rock foot into the desert floor, matching the skirt in mountain_variety.gd.
float fan_field = value_noise(base_uv * 0.030 + vec2(63.0, 17.0));
float fan_low = smoothstep(ground_height + 0.2, ground_height + 5.0, h)
              * (1.0 - smoothstep(ground_height + 6.0, ground_height + 15.0, h));
float fan_edge = 4.0 * rock_in * (1.0 - rock_in);
float talus_m = clamp(fan_edge * (0.35 + 0.65 * fan_field) * (0.55 + 0.45 * fan_low), 0.0, 1.0);
vec3 talus = mix(ground * 0.80, rock, 0.58) * (0.93 + 0.12 * fan_field);
// Loose scree at the foot of every rock mass, keyed to the apron height band.
float scree = smoothstep(0.58, 0.90, value_noise(base_uv * 0.045 + vec2(53.0, 11.0)))
            * (1.0 - rock_in) * smoothstep(ground_height + 0.6, ground_height + 7.0, h);

 // --- 5./6. banks ----------------------------------------------------------
 vec3 bank = mix(ground * 0.84, macro_wet, macro_strength);
 bank *= 0.96 + texture(bank_tex, base_uv * 0.012).r * 0.035;
 bank = mix(bank, bank * vec3(0.90, 1.02, 0.96), 0.45);
 bank = desaturate(bank, 0.55);
 vec3 shorec = mix(ground * 0.91, macro_wet * vec3(1.04,1.03,1.0), macro_strength);
 shorec *= 0.97 + texture(shore_tex, base_uv * 0.010).r * 0.03;
 shorec = mix(shorec, shorec * vec3(1.06, 1.05, 0.98), 0.45);
 shorec *= 0.90 + macro3 * 0.16;
 shorec = desaturate(shorec, 0.58);
 // The band edges are warped by noise so they never read as a painted stripe.
 float lake_w = shore_width * (0.72 + 0.56 * value_noise(base_uv * 0.030 + vec2(7.0, 19.0)));
 float bank_w = bank_width * (0.70 + 0.60 * value_noise(base_uv * 0.045 + vec2(23.0, 3.0)));
 float lake_band = 1.0 - smoothstep(0.0, lake_w, max(lake_d, 0.0));
 float river_band = (1.0 - smoothstep(0.0, bank_w, shore_d)) * (1.0 - lake_band);
 float lip = 1.0 - smoothstep(0.0, 5.0, min(shore_d, max(lake_d, 0.0)));

 // --- 7. ramps: compacted, flatter and lighter than the desert floor -------
 vec3 ramp = ground * (1.04 + (texture(ramp_tex, base_uv * 0.075).r - 0.5) * 0.06);
 ramp *= 0.94 + macro3 * 0.12;
 ramp_m *= 0.72 + 0.28 * value_noise(base_uv * 0.11);

 // --- blend ---------------------------------------------------------------
 // rock_in gates top/cliff HARD: inside the rock masses (and their scree aprons)
 // the plateau top/cliff tints must never bleed back onto the mountains.
 float rock_gate = 1.0 - smoothstep(0.10, 0.50, rock_in);
 vec3 col = ground;
 col = mix(col, gravel * 1.06, scree * 0.70);
 col = mix(col, top, clamp(top_m, 0.0, 1.0) * rock_gate);
 col = mix(col, cliff, clamp(cliff_m, 0.0, 1.0) * rock_gate * (1.0 - top_m * 0.25));
 col = mix(col, rock, clamp(rock_m, 0.0, 1.0));
 col = mix(col, talus, talus_m * 0.60);
 col = mix(col, ramp, clamp(ramp_m, 0.0, 1.0));
 col = mix(col, shorec, clamp(lake_band, 0.0, 1.0) * 0.92 * (1.0 - rock_in));
 col = mix(col, bank, clamp(river_band, 0.0, 1.0) * 0.92 * (1.0 - rock_in));
 // 云影统一作用在合成结果上：原先只乘在 ground 上，随后被 top/cliff 等
 // mix 覆盖 -> 台地顶成了"没有层次的均匀亮板"（实测台地顶 158 均匀 vs
 // 平地 76~160 有色域变化）。移到此处后所有地表层共享大尺度明暗。
 col *= 1.0 - smoothstep(0.48, 0.86, cloud) * 0.16;
	// Warm sci-fi lighting otherwise pushes the albedo toward orange; keep the
	// terrain in the requested warm-grey / muted rose-brown range.
	col *= vec3(1.05, 0.99, 0.90);

 // --- wet lips, road wear and per-layer roughness --------------------------
 float wet = clamp(max(lake_band * 0.85, river_band), 0.0, 1.0);
 col = mix(col, col * vec3(0.80, 0.78, 0.75), lip * 0.30 * (1.0 - rock_in));
 col = mix(col, col * vec3(0.91, 0.89, 0.86), wet * 0.25);
 float traffic = 0.0;
 if (main_run > 0.01) {
  vec2 lane_delta = p.xz - main_lane.xy;
  float along = dot(lane_delta, main_lane.zw);
  float side = abs(lane_delta.x * main_lane.w - lane_delta.y * main_lane.z);
  traffic = (1.0 - smoothstep(main_width * 0.32, main_width * 0.58, side))
          * smoothstep(-5.0, 2.0, along)
          * (1.0 - smoothstep(main_run, main_run + 8.0, along));
 }
 col = mix(col, col * vec3(1.03, 1.01, 0.97), traffic * 0.35);
 rough = mix(rough, 0.44, wet);
 rough = mix(rough, 0.86, clamp(ramp_m, 0.0, 1.0));
 rough = mix(rough, 0.82, clamp(top_m, 0.0, 1.0));
 rough = mix(rough, 0.94, rock_in);
 rough = mix(rough, 0.90, clamp(cliff_m, 0.0, 1.0) * 0.7);

 if (debug_masks > 0.5) {
  if (debug_masks > 1.5) {
   // Hard distance rings: red = within 8 m of the water footprint,
   // yellow = within 20 m, so the band width can be measured in pixels.
   float r8 = 1.0 - step(8.0, shore_d);
   float r20 = 1.0 - step(20.0, shore_d);
   col = vec3(r20, r8, 0.0);
  } else {
   // soft = plateau outline ring, green = river bank, blue = lake band.
   col = vec3(clamp(1.0 - abs(plateau_d) / 40.0, 0.0, 1.0),
              clamp(river_band, 0.0, 1.0),
              clamp(lake_band, 0.0, 1.0));
  }
  rough = 1.0;
 }
 ALBEDO = col;
 ROUGHNESS = clamp(rough, 0.1, 1.0);
 SPECULAR = 0.22;
 METALLIC = 0.0;

 // 法线贴图 20m 平铺在光照下会形成规则条纹（实测水平波纹的主因）：
 // 扰动 UV + 双尺度混合后周期互消，保留颗粒感而去掉条纹。
 vec3 n_sand = normalize(mix(texture(sand_normal, uv_g * 0.050).xyz,
                             texture(sand_normal, uv_g * 0.113 + vec2(0.41, 0.23)).xyz,
                             0.5) * 2.0 - 1.0 + vec3(0.0, 1.0, 0.0));
 vec3 n_rock = triplanar(rock_normal, p, wnr, 0.062) * 2.0 - 1.0;
 vec3 n_cliff = triplanar(cliff_normal, p, wnr, 0.070) * 2.0 - 1.0;
 vec3 nrm = n_sand;
 nrm = mix(nrm, n_rock, rock_in);
 nrm = mix(nrm, n_cliff, clamp(cliff_m, 0.0, 1.0) * 0.85);
 nrm = mix(nrm, n_sand * 0.55, clamp(top_m, 0.0, 1.0) * 0.45);
 nrm = mix(nrm, n_sand * 0.70, clamp(ramp_m, 0.0, 1.0) * 0.4);
 // Rock faces get ~2.5x normal depth: at the shared strength the crag texture
 // flattens out at RTS distance and the range reads as poured clay.
 // Rock faces need a real perturbation: nrm from the detail map is ~±0.3, so at
 // the old 0.12 effective depth the bend was about 2 degrees - invisible at RTS
 // distance. ~0.5 here is what actually reads as fractured rock.
 // Procedural micro-bump: a noise-GRADIENT perturbation computed per-pixel,
 // bypassing both the 2 m mesh resolution and the low-frequency sampled normal
 // maps. This is what finally breaks the "poured wax" surface into fractured
 // rock at RTS distance.
 // 程序化凹凸用旋转交叉噪声：value_noise 的格点结构在【梯度】下最明显，
 // 直接用作 bump 会在平地上留下网格状明暗条纹（实测 4.2m 周期，多轮
 // 贴图层排查无效后定位到此）。terrain_noise 的 45 度交错采样消除方向性。
 vec2 gq = base_uv * 0.24;
 float gn0 = terrain_noise(gq);
 vec2 bump_g = vec2(terrain_noise(gq + vec2(0.85, 0.0)) - gn0,
                    terrain_noise(gq + vec2(0.0, 0.85)) - gn0);
 nrm.x += bump_g.x * 1.7 * rock_in;
 nrm.y += bump_g.y * 1.7 * rock_in;
 vec3 bumped = normalize(wnr + vec3(nrm.x, 0.0, nrm.y)
     * normal_strength * (1.0 + 8.0 * rock_in));
 NORMAL = normalize((VIEW_MATRIX * vec4(bumped, 0.0)).xyz);
}
