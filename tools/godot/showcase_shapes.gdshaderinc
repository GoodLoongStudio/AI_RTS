uniform float river_z = 10.0;
uniform float showcase_world_scale = 1.0;
uniform vec2 lake_position = vec2(-67.0, 103.0);

float river_center(float x) {
 return sin(x * .022) * 12.0 + sin(x * .057 + 1.15) * 5.0;
}
float river_half(float x) {
 return 14.0 * (1.0 + .10 * sin(x * .031 + .6) + .035 * sin(x * .081));
}
float river_distance(vec2 p) {
 return abs(p.y - river_z - river_center(p.x)) - river_half(p.x);
}
float lake_distance(vec2 p) {
 vec2 q = (p - lake_position) / vec2(1.25, .90);
 float a = atan(q.y, q.x);
 float radius = 29.0 * (1.0 + .13*sin(3.0*a+.4) + .065*cos(5.0*a-1.0));
 return length(q) - radius;
}
