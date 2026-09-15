"""One-off probe helpers: resolve the game root without hardcoded drive letters."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from rtsmap.contract import G4_AIRTS, MAPGEN_ROOT  # noqa: E402

AIRTS = Path(G4_AIRTS)
GENERATED = AIRTS / "source" / "match" / "maps" / "generated"
DEFAULT_MAP_ID = "16-0-1ca6e21aa1"
DEFAULT_HEIGHT = GENERATED / DEFAULT_MAP_ID / "height_data.bin"
