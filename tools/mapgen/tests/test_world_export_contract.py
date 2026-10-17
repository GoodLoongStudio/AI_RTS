"""World dimensions and source raster are deliberately separate contracts."""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from rtsmap.gates import g4_export

def test_world_contract_is_512_unscaled():
    assert g4_export.world_contract() == dict(export_contract_version='world-meters-v2',
        size=[512, 512], source_size=[256, 256], cell_m=2.0, root_scale=[1, 1, 1], height_scale=1)

def test_transform_expands_xz_once_not_height():
    value = g4_export.fmt_transform(10, 7, 20, scale=1, xz_scale=2)
    assert value == 'Transform3D(2.0, 0, 0.0, 0, 1, 0, -0.0, 0, 2.0, 20.000, 7.000, 40.000)'

def test_map_identity_separates_world_contract(monkeypatch):
    config = dict(controls={'river_enabled': 1}, schema_version=2)
    current = g4_export.make_map_id(36, 10, config)
    monkeypatch.setitem(g4_export.G4_PARAMS_DEFAULTS, 'world_scale_m', 1.0)
    assert current != g4_export.make_map_id(36, 10, config)

def test_install_requires_new_geometry_contract(tmp_path):
    old = tmp_path / 'old'
    old.mkdir()
    (old / 'geometry_contract.json').write_text(json.dumps(dict(export_contract_version='old')), encoding='utf-8')
    import pytest
    with pytest.raises(ValueError, match='Old map export'):
        g4_export.install_map(old, 'old', tmp_path / 'game')
