"""Read the existing G1 library. Source coordinates and territory are immutable."""
import math

from ..gates.g1_starts import evaluate_constraints, first_violation
from ..grid import read_json
from ..gate import is_approved
from .settings import SPACING


def g1_source_root(project):
    runs = project / 'runs'
    if runs.is_dir() and any((child / 'G1' / 'mapspec.json').is_file() for child in runs.iterdir()):
        return runs
    current = project / 'runs_512'
    return current if current.exists() else runs


def prepare_g1_library(project):
    """Create matching inputs without overwriting the old 256-cell library."""
    from ..contract import G1_DEFAULTS, GRID_H, GRID_W
    from ..gates.g1_starts import run_one
    from ..grid import MapGrid
    root = project / 'runs_512'
    for seed in (16, 35, 61):
        path = root / str(seed) / 'G1' / 'mapgrid.npz'
        if path.exists() and MapGrid.load(path).get('territory').shape == (GRID_H, GRID_W):
            continue
        run_one(seed, root, dict(G1_DEFAULTS))


def spacing_of(distance):
    return next(key for key, (lo, hi) in SPACING.items() if key != 'any' and lo <= distance < hi)


def layout_catalog(project):
    root = g1_source_root(project)
    layouts = []
    for folder in sorted(root.iterdir(), key=lambda path: path.name):
        if not folder.name.isdigit():
            continue
        path = folder / 'G1' / 'mapspec.json'
        if not path.exists() or not (folder / 'G1' / 'mapgrid.npz').exists():
            continue
        spec = read_json(path)
        if not spec.get('accepted') or first_violation(evaluate_constraints(spec['starts'], spec['params'])):
            continue
        seed = int(folder.name)
        if spec.get('master_seed') != seed:
            continue
        starts = spec['starts']
        distance = min(math.dist(a, b) for i, a in enumerate(starts) for b in starts[i+1:])
        layouts.append(dict(seed=seed, starts=starts, nearest_pair_m=round(distance, 1),
                            spacing=spacing_of(distance), approved=is_approved(root, seed, 'G1')))
    return sorted(layouts, key=lambda item: item['seed'])
