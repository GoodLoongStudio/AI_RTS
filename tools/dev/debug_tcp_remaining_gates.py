"""Isolated desktop rendered-frame verification. No foreground or OS input calls."""
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path('G:/AIRTS/AI_RTS')
ENGINE = 'G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe'
FROZEN = '65795566d1ebf1e309ed02f7fddc45c743d54508738693cb826ceb8da9b60b47'
sys.path.insert(0, str(ROOT/'tools/dev'))
from debug_tcp_lifecycle_probe import receive

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

class OwnedProcess:
    """CreateProcessW really passes lpDesktop; subprocess.STARTUPINFO does not."""
    def __init__(self, cmd, env, desktop, log):
        import msvcrt
        class STARTUPINFO(ctypes.Structure):
            _fields_ = [('cb',wintypes.DWORD),('lpReserved',wintypes.LPWSTR),('lpDesktop',wintypes.LPWSTR),('lpTitle',wintypes.LPWSTR),('dwX',wintypes.DWORD),('dwY',wintypes.DWORD),('dwXSize',wintypes.DWORD),('dwYSize',wintypes.DWORD),('dwXCountChars',wintypes.DWORD),('dwYCountChars',wintypes.DWORD),('dwFillAttribute',wintypes.DWORD),('dwFlags',wintypes.DWORD),('wShowWindow',wintypes.WORD),('cbReserved2',wintypes.WORD),('lpReserved2',ctypes.c_void_p),('hStdInput',wintypes.HANDLE),('hStdOutput',wintypes.HANDLE),('hStdError',wintypes.HANDLE)]
        class PROCESSINFO(ctypes.Structure):
            _fields_ = [('hProcess',wintypes.HANDLE),('hThread',wintypes.HANDLE),('dwProcessId',wintypes.DWORD),('dwThreadId',wintypes.DWORD)]
        self.kernel = ctypes.WinDLL('kernel32',use_last_error=True)
        self.kernel.CreateProcessW.argtypes = [wintypes.LPCWSTR,wintypes.LPWSTR,ctypes.c_void_p,ctypes.c_void_p,wintypes.BOOL,wintypes.DWORD,ctypes.c_void_p,wintypes.LPCWSTR,ctypes.POINTER(STARTUPINFO),ctypes.POINTER(PROCESSINFO)]
        self.kernel.CreateProcessW.restype = wintypes.BOOL
        self.kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE,ctypes.POINTER(wintypes.DWORD)]
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.SetHandleInformation.argtypes = [wintypes.HANDLE,wintypes.DWORD,wintypes.DWORD]
        stdout = msvcrt.get_osfhandle(log.fileno())
        self.kernel.SetHandleInformation(stdout,1,1)
        si = STARTUPINFO(); si.cb = ctypes.sizeof(si); si.lpDesktop = 'WinSta0\\'+desktop
        si.dwFlags = 0x100 | 1; si.wShowWindow = 4
        si.hStdOutput = stdout; si.hStdError = stdout
        pi = PROCESSINFO()
        block = ctypes.create_unicode_buffer('\0'.join(k+'='+v for k,v in sorted(env.items()))+'\0\0')
        command = ctypes.create_unicode_buffer(subprocess.list2cmdline(cmd))
        if not self.kernel.CreateProcessW(cmd[0],command,None,None,True,0x08000000|0x400,block,str(ROOT),ctypes.byref(si),ctypes.byref(pi)):
            raise ctypes.WinError(ctypes.get_last_error())
        self.handle = pi.hProcess; self.pid = pi.dwProcessId
        self.kernel.CloseHandle(pi.hThread)
        self.kernel.SetHandleInformation(stdout,1,0)
    def poll(self):
        code = wintypes.DWORD()
        if not self.kernel.GetExitCodeProcess(self.handle,ctypes.byref(code)):
            raise ctypes.WinError(ctypes.get_last_error())
        return None if code.value == 259 else code.value
    def wait(self,timeout):
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            code = self.poll()
            if code is not None: return code
            time.sleep(.1)
        raise subprocess.TimeoutExpired(str(self.pid),timeout)

def main():
    out = ROOT/'agent/runs/2026-10-11-debug-tcp-lifecycle/gpu-infrastructure'/time.strftime('%Y%m%d-%H%M%S')
    out.mkdir(parents=True, exist_ok=False)
    source = ROOT/'source/net/DebugControlServer.gd'
    assert hashlib.sha256(source.read_bytes()).hexdigest() == FROZEN
    user = ctypes.WinDLL('user32', use_last_error=True)
    user.CreateDesktopW.argtypes = [wintypes.LPCWSTR,wintypes.LPCWSTR,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p]
    user.CreateDesktopW.restype = wintypes.HANDLE
    user.SetThreadDesktop.argtypes = [wintypes.HANDLE]
    user.SetThreadDesktop.restype = wintypes.BOOL
    name = 'AIRTS_GPU_'+str(os.getpid())
    desktop = user.CreateDesktopW(name,None,None,0,0x01ff,None)
    if not desktop or not user.SetThreadDesktop(desktop):
        raise ctypes.WinError(ctypes.get_last_error())
    startup = subprocess.STARTUPINFO()
    startup.lpDesktop = name
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 4  # SW_SHOWNOACTIVATE, isolated desktop from process creation.
    dcs = port()
    cmd = [ENGINE,'--path',str(ROOT),'--display-driver','windows','--rendering-method','forward_plus','--rendering-driver','vulkan','--windowed','--resolution','1280x720','--audio-driver','Dummy','res://tools/dev/debug_tcp_match_fixture.tscn','--','--debugport',str(dcs),'--tcp-out='+str(out),'--gpu-probe']
    result = {'started':time.time(),'desktop':name,'command':cmd,'sourcehash':FROZEN,'source_mtime':source.stat().st_mtime,'out':str(out),'checks':{},'phases':[]}
    log = (out/'visible.log').open('xb')
    p = OwnedProcess(cmd,dict(os.environ,AIRTS_INSTANCE_DIR='',AIRTS_INSTANCE_STRICT_DCS='0',GODOT_BRIDGE_PORT=str(port())),name,log)
    result['pid'] = p.pid
    deadline = time.monotonic()+240
    def wait_file(name, timeout=100):
        until = min(deadline,time.monotonic()+timeout)
        while time.monotonic()<until:
            f = out/name
            if f.exists():
                try: return json.loads(f.read_text(encoding='utf-8'))
                except json.JSONDecodeError: pass
            if p.poll() is not None: raise RuntimeError('Godot exited '+str(p.returncode))
            time.sleep(.1)
        raise TimeoutError(name)
    def call(body):
        with socket.create_connection(('127.0.0.1',dcs),timeout=10) as s:
            s.sendall((json.dumps(body)+'\n').encode())
            return receive(s)
    try:
        result['ready'] = wait_file('ready-1.json')
        identity = wait_file('gpu-identity.json')
        result['identity'] = identity
        # Observe ALL windows, including hidden, rather than silently filtering them out.
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND,ctypes.POINTER(wintypes.DWORD)]
        user.IsWindowVisible.argtypes = [wintypes.HWND]
        user.IsIconic.argtypes = [wintypes.HWND]
        cbtype = ctypes.WINFUNCTYPE(wintypes.BOOL,wintypes.HWND,wintypes.LPARAM)
        user.EnumDesktopWindows.argtypes = [wintypes.HANDLE,cbtype,wintypes.LPARAM]
        user.EnumDesktopWindows.restype = wintypes.BOOL
        windows = []
        @cbtype
        def collect(hwnd,_):
            pid = wintypes.DWORD()
            user.GetWindowThreadProcessId(hwnd,ctypes.byref(pid))
            windows.append({'hwnd':int(hwnd),'pid':pid.value,'visible':bool(user.IsWindowVisible(hwnd)),'minimized':bool(user.IsIconic(hwnd))})
            return True
        result['enum_rc'] = bool(user.EnumDesktopWindows(desktop,collect,0))
        result['enum_error'] = ctypes.get_last_error()
        result['desktop_windows'] = windows
        hwnd = identity['native_hwnd']
        result['native_window'] = {'hwnd':hwnd,'visible':bool(user.IsWindowVisible(hwnd)),'minimized':bool(user.IsIconic(hwnd))}
        # Actual command line independently observed; hidden PowerShell helper, no GUI.
        ps = subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',f'Get-CimInstance Win32_Process -Filter "ProcessId={p.pid}" | Select-Object ProcessId,CommandLine,CreationDate | ConvertTo-Json -Compress'],capture_output=True,text=True,creationflags=0x08000000,timeout=15)
        result['actual_process'] = ps.stdout.strip()
        assert identity['display_driver']=='Windows' or identity['display_driver']=='windows', identity
        assert identity['gpu'] and identity['frames_drawn']>0
        assert identity['window_mode'] != 1 and not result['native_window']['minimized']
        assert identity['entities']==46, identity['entities']
        result['status'] = call({'op':'status'})
        # Three consecutive unrecorded steady windows; no synchronous screenshots in samples.
        for i in range(3):
            (out/'measure-start').write_text('start')
            time.sleep(20)
            (out/'measure-stop').write_text('stop')
            data = wait_file('measurement.json',10)
            path = out/f'steady-{i}.json'
            (out/'measurement.json').rename(path)
            result['phases'].append(str(path))
        result['checks']['dcs_screenshot'] = call({'op':'screenshot','path':str(out/'dcs-shot.png')})
        (out/'capture-start').write_text('start')
        time.sleep(3)
        worker = next(u for u in result['status']['units'] if u.get('mine') and u.get('movement'))
        result['action'] = {'utc':time.time(),'unit':worker['name'],'before':worker['pos'],'response':call({'op':'move','units':[worker['name']],'dest':[worker['pos'][0]+14,worker['pos'][2]+8]})}
        time.sleep(58)
        result['after'] = call({'op':'status'})
        result['perf'] = call({'op':'perf'})
        (out/'quit').write_text('quit')
        result['game_rc'] = p.wait(timeout=30)
    except Exception as exc:
        result['error'] = repr(exc)
    finally:
        if p.poll() is None:
            (out/'quit').write_text('quit')
            try: p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                subprocess.run(['taskkill','/PID',str(p.pid),'/T','/F'],capture_output=True,creationflags=0x08000000,timeout=15)
                p.wait(timeout=15)
        log.close()
        result['cleanup_ok'] = p.poll() is not None
        result['ended'] = time.time()
        result['sourcehash_end'] = hashlib.sha256(source.read_bytes()).hexdigest()
        (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print(json.dumps({'out':str(out),'error':result.get('error'),'cleanup_ok':result['cleanup_ok']}))
    return 1 if 'error' in result else 0

if __name__ == '__main__':
    raise SystemExit(main())
