"""Fast bullet flinch and a terminal blast trajectory, in Blender world space."""
import math
from mathutils import Quaternion

HIT_SECONDS = 0.3
BLAST_SECONDS = 1.8


def curve(t, keys):
    for (a, x), (b, y) in zip(keys, keys[1:]):
        if t <= b:
            u = max(0.0, min(1.0, (t-a)/(b-a)))
            return x + (y-x)*u
    return keys[-1][1]


def bullet_flinch(rots, t):
    # One-frame impact, short recoil, small counter-motion, then recovery.
    kick = curve(t, [(0, 0), (1/30, 1), (2/30, .62), (.1, .24), (.167, -.10), (.3, 0)])
    for bone, factor in [('Spine_01', .15), ('Spine_02', .55), ('Spine_03', 1),
                         ('Neck', 1.15), ('Head', 1.25), ('Clavicle_L', .8), ('Clavicle_R', 1)]:
        rots[bone] = Quaternion((0, 0, 1), math.radians(5)*kick*factor) @ Quaternion(
            (1, 0, 0), math.radians(-14)*kick*factor) @ rots[bone]


def blast_source_time(t):
    return curve(t, [(0, 0), (.067, .12), (.18, .65), (.45, 1.1),
                     (.9, 1.5), (1.1, 1.9), (1.4, 2.4), (BLAST_SECONDS, 2.4)])


def blast_death(rots, hip, idle_rots, idle_hip, t):
    # Release the support hand quickly; preserve the existing natural fall pose.
    release = max(0.0, min(1.0, t/.18))
    release = release*release*(3-2*release)
    airborne = max(0.0, math.sin(math.pi*max(0.0, min(1.0, (t-.067)/.833))))
    pitch = Quaternion((1, 0, 0), math.radians(-12)*airborne)
    for bone in rots:
        rots[bone] = pitch @ idle_rots[bone].slerp(rots[bone], release)
    hip = idle_hip.lerp(hip, release)
    elapsed = max(0.0, min(t, .9)-.067)
    if t <= .9:
        hip.z = idle_hip.z + 3.8*elapsed - 5.7*elapsed*elapsed
    # After first contact, friction stops the slide; the last 0.4s is a dead hold.
    settle = min(max(t-.9, 0.0), .5)
    hip.y = idle_hip.y + 2.45*elapsed + .14*(1-math.exp(-10*settle))
    return rots, hip
