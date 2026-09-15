"""Redraw installed map minimaps with the G4-style compositor."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap.contract import G4_AIRTS  # noqa: E402
from rtsmap.viz.g4_style import compose_g4_style_from_bin  # noqa: E402
from PIL import Image

MAP_ID = sys.argv[1] if len(sys.argv) > 1 else "16-0-1ca6e21aa1"
AIRTS = Path(G4_AIRTS)
SRC = AIRTS / "source" / "match" / "maps" / "generated" / MAP_ID
BIN = SRC / "height_data.bin"


def main() -> int:
    if not BIN.is_file():
        raise SystemExit(f"missing {BIN}")
    img = compose_g4_style_from_bin(BIN)
    preview = Image.fromarray(img).resize((512, 512), Image.LANCZOS)
    targets = [
        SRC / "minimap_preview.png",
        AIRTS / "assets" / "map_previews" / f"map_{MAP_ID}.png",
    ]
    for path in targets:
        path.parent.mkdir(parents=True, exist_ok=True)
        preview.save(path)
        print("wrote", path)
    print("REPORT", json.dumps({"map_id": MAP_ID, "size": list(preview.size)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
