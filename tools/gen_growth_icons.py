#!/usr/bin/env python3
"""Extract growth SVG icons from the retained design source; dry-run writes nothing."""

import argparse
import json
from pathlib import Path
import re


ICON_FILES = (
    ('ic-credits', 'credits.svg'), ('ic-power', 'power.svg'),
    ('ic-build', 'build.svg'), ('ic-infantry', 'infantry.svg'),
    ('ic-armor', 'armor.svg'), ('ic-air', 'air.svg'),
    ('ic-repair', 'repair.svg'), ('ic-attack', 'attack.svg'),
)
HEADER = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">'


def main():
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / 'agent/manifest.json').read_text(encoding='utf-8-sig'))
    source = Path(manifest['workspace_layout']['workspace_archive_root']) / '设计资料/ui_design/icons_rts_commands.html'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=source)
    parser.add_argument('--output', type=Path, default=root / 'assets/ui/icons/growth')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    html = args.source.read_text(encoding='utf-8')
    icons = {}
    for symbol, filename in ICON_FILES:
        match = re.search(r'<symbol id="%s"[^>]*>(.*?)</symbol>' % re.escape(symbol), html, re.S)
        if not match:
            parser.error('Missing symbol: ' + symbol)
        body = '\n'.join(line.rstrip() for line in match.group(1).strip().splitlines())
        icons[filename] = HEADER + '\n' + body + '\n</svg>\n'
    if not args.dry_run:
        args.output.mkdir(parents=True, exist_ok=True)
        for filename, svg in icons.items():
            (args.output / filename).write_text(svg, encoding='utf-8', newline='\n')
    print(json.dumps({'source': str(args.source.resolve()), 'output': str(args.output.resolve()),
                      'icons': list(icons), 'dry_run': args.dry_run,
                      'written': 0 if args.dry_run else len(icons)}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
