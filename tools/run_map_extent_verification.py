"""Run isolated map Match probes, optionally on a private Windows desktop."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
from run_augment_verification import port

ROOT = Path(__file__).resolve().parents[1]


def terminate_owned_process(process):
    if process.poll() is not None:
        return
    if os.name == 'nt':
        # The Godot console launcher owns a GUI-executable child even in headless mode.
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       creationflags=subprocess.CREATE_NO_WINDOW, timeout=10, check=False)
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--rendered', action='store_true')
    parser.add_argument('--renderer', choices=['forward_plus', 'gl_compatibility'], default='forward_plus')
    parser.add_argument('--extra', default='')
    parser.add_argument('--map', default='')
    args = parser.parse_args()
    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, AIRTS_INSTANCE_DIR='', AIRTS_INSTANCE_STRICT_DCS='0',
               GODOT_BRIDGE_PORT=str(port()), AIRTS_MAP_OUTPUT=str(output / 'measurements.json'),
               AIRTS_MAP_BASELINE='1' if args.baseline else '0', AIRTS_MAP_EXTRA=args.extra, AIRTS_MAP_ONLY=args.map)
    desktop = None
    startup = None
    if args.rendered:
        import ctypes
        from ctypes import wintypes
        user32 = ctypes.WinDLL('user32', use_last_error=True)
        user32.CreateDesktopW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, ctypes.c_void_p,
                                         wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
        user32.CreateDesktopW.restype = wintypes.HANDLE
        user32.CloseDesktop.argtypes = [wintypes.HANDLE]
        name = f'AIRTS_Map512_{os.getpid()}'
        desktop = user32.CreateDesktopW(name, None, None, 0, 0x10000000, None)
        if not desktop:
            raise ctypes.WinError(ctypes.get_last_error())
        startup = subprocess.STARTUPINFO()
        startup.lpDesktop = name
        env['AIRTS_MAP_SHOTS'] = str(output)
    command = [args.godot, *(['--rendering-method', args.renderer] if args.rendered else ['--headless']),
               '--path', str(ROOT), '--quit-after', '200000',
               'res://tests/automated/MapExtentMatchTest.tscn', '--', '--debugport', str(port())]
    start = time.time()
    try:
        with (output / 'probe.log').open('wb') as log:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW, startupinfo=startup)
            try:
                code = process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                terminate_owned_process(process)
                code = -9
        text = (output / 'probe.log').read_text(encoding='utf-8', errors='replace')
        assertions_passed = code == 0 and 'Map extent match test completed: 0 failure(s)' in text
        suite = json.loads((ROOT / 'config/full_regression_suite.json').read_text(encoding='utf-8'))
        forbidden_hits = [pattern for pattern in suite['forbidden_output_patterns'] if re.search(pattern, text)]
        errors = re.findall(r'^ERROR:.*$', text, flags=re.MULTILINE)
        dummy_count = len(re.findall(r'ERROR: Parameter "t" is null\.\r?\n\s+at: texture_2d_get \(\./servers/rendering/dummy/storage/texture_storage.h:110\)', text))
        unexpected = list(errors)
        for _ in range(dummy_count):
            unexpected.remove('ERROR: Parameter "t" is null.')
        passed = assertions_passed and not forbidden_hits and not unexpected
        (output / 'run.json').write_text(json.dumps(dict(pid=process.pid, rc=code, command=command,
            wall_seconds=time.time()-start, assertions_passed=assertions_passed, passed=passed,
            log_clean=not errors and not forbidden_hits, forbidden_hits=forbidden_hits,
            known_headless_dummy_texture_errors=dummy_count, unexpected_engine_errors=unexpected,
            cleanup_ok=process.poll() is not None), indent=2), encoding='utf-8')
        print(json.dumps(dict(out=str(output), rc=code, assertions_passed=assertions_passed, passed=passed)))
        return 0 if passed else 1
    finally:
        if desktop:
            user32.CloseDesktop(desktop)

if __name__ == '__main__':
    raise SystemExit(main())
