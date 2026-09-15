"""G2/G4 俯视底图必须走沙地/深青水，不能再是平涂亮蓝+橙色块。"""
import numpy as np

from rtsmap.contract import G2_DEFAULTS, GRID_H, GRID_W
from rtsmap.viz.g4_style import compose_g4_style


def test_g4_style_water_is_dark_teal_not_bright_blue():
    height = np.full((GRID_H, GRID_W), G2_DEFAULTS["ground_level"], dtype=np.float32)
    height[80:120, 40:220] = G2_DEFAULTS["water_level"]
    height[40:70, 90:140] = G2_DEFAULTS["plateau_level"]
    img = compose_g4_style(height)
    water = img[80:120, 40:220]
    sand = img[10:30, 10:30]
    top = img[40:70, 90:140]
    water_mean = water.mean(axis=(0, 1))
    sand_mean = sand.mean(axis=(0, 1))
    top_mean = top.mean(axis=(0, 1))
    assert water_mean[2] < 110, water_mean
    assert water_mean[0] < water_mean[2] + 8
    assert sand_mean[0] > 90
    assert sand_mean[1] > 70
    assert not np.allclose(sand_mean, (228, 222, 206), atol=12)
    assert not np.allclose(top_mean, (208, 140, 48), atol=18)
    assert top_mean.mean() > water_mean.mean()
