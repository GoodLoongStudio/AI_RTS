"""Directed, meandering tributaries for the strategic river corridor."""
import math

import numpy as np


def tributary_curve(mouth, downstream, side, length, mouth_width, rng):
    """Return source-to-mouth samples; the mouth enters with downstream flow."""
    downstream = np.asarray(downstream, dtype=float)
    downstream /= np.linalg.norm(downstream)
    normal = side * np.array([-downstream[1], downstream[0]])
    angle = math.radians(float(rng.uniform(32., 52.)))
    arrival = downstream * math.cos(angle) - normal * math.sin(angle)
    source = mouth - downstream * length * rng.uniform(.62, .95) + normal * length
    control1 = source + downstream * length * rng.uniform(.25, .45)
    control1 -= normal * length * rng.uniform(.10, .40)
    control2 = mouth - arrival * length * .42
    t = np.linspace(0., 1., 97)
    u = t[:, None]
    points = ((1-u)**3 * source + 3*(1-u)**2*u * control1
              + 3*(1-u)*u*u * control2 + u**3 * mouth)
    axis = mouth-source
    cross = np.array([-axis[1], axis[0]]) / np.linalg.norm(axis)
    # Zero value AND derivative at either end preserve source/mouth tangents.
    phase = float(rng.uniform(0., math.tau))
    bend = (np.sin(np.pi*t)**2 * np.sin(t*math.tau*rng.uniform(1.1, 1.7)+phase)
            * length * rng.uniform(.08, .15))
    points += bend[:, None] * cross
    widths = 2.5 + (mouth_width-2.5) * t**.65
    return points, widths
