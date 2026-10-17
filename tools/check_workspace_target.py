#!/usr/bin/env python3
"""Read-only preflight for the configured AIRTS development checkout."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def within(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def classify(path, layout, development_root):
    runtime = development_root / layout['protected_runtime_subdirectory']
    if within(path, runtime):
        return 'model-runtime'
    for subdirectory in layout['non_source_subdirectories']:
        if within(path, development_root / subdirectory):
            return 'generated-or-operational'
    if within(path, development_root):
        return 'development-source'
    categories = (
        ('packaged-delivery', [layout['packaged_delivery_root']]),
        ('independent-project', layout['other_project_roots']),
        ('reference-or-backup', layout['reference_roots']),
        ('engine-installation', layout['engine_roots']),
    )
    for category, roots in categories:
        if any(within(path, Path(root).resolve()) for root in roots):
            return category
    if within(path, development_root.parent):
        return 'workspace-other'
    return 'outside-workspace'


def check(target, mode):
    checker_root = Path(__file__).resolve().parent.parent
    manifest = json.loads((checker_root / 'agent/manifest.json').read_text(encoding='utf-8-sig'))
    layout = manifest['workspace_layout']
    development_root = Path(layout['primary_development_root']).resolve()
    if checker_root != development_root:
        raise ValueError('Checker is outside the configured primary checkout; use its tools/check_workspace_target.py.')
    if not (development_root / 'project.godot').is_file():
        raise ValueError('The configured primary checkout has no project.godot.')
    git_result = subprocess.run(
        ['git', '-C', str(development_root), 'rev-parse', '--show-toplevel'],
        capture_output=True, text=True, encoding='utf-8', timeout=10,
    )
    if git_result.returncode != 0:
        raise ValueError('Cannot verify the Git root of the primary checkout.')
    git_root = Path(git_result.stdout.strip()).resolve()
    if git_root != development_root:
        raise ValueError('Git root does not match the configured primary checkout.')

    # abspath normalizes dot segments without following directory links.
    requested = Path(os.path.abspath(target))
    resolved = requested.resolve()
    requested_role = classify(requested, layout, development_root)
    resolved_role = classify(resolved, layout, development_root)
    source_target = requested_role == resolved_role == 'development-source'
    allowed = mode == 'inspect' or source_target
    result = {
        'mode': mode,
        'checker_root': str(checker_root),
        'development_root': str(development_root),
        'git_root': str(git_root),
        'requested_target': str(requested),
        'resolved_target': str(resolved),
        'requested_role': requested_role,
        'resolved_role': resolved_role,
        'exists': resolved.exists(),
        'allowed_for_development': source_target,
        'decision': 'inspect-only' if mode == 'inspect' else ('allow' if allowed else 'reject'),
        'reason': (
            'Read-only classification; this mode grants no write authorization.' if mode == 'inspect'
            else 'Target belongs to the primary source checkout.' if allowed
            else 'Target is not primary source. Correct the path; do not move or clean projects to bypass this check.'
        ),
    }
    return result, 0 if allowed else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('develop', 'inspect'), default='develop')
    parser.add_argument('--target', required=True, help='Actual path; relative paths use the caller working directory.')
    args = parser.parse_args()
    try:
        result, code = check(args.target, args.mode)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        result, code = {'decision': 'error', 'reason': str(exc)}, 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return code


if __name__ == '__main__':
    sys.exit(main())
