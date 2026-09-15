$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    throw '需要 Python 3.11+，并已加入 PATH。'
}

$ver = & python -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"
$parts = $ver.Split('.')
if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 11)) {
    throw "需要 Python 3.11+，当前是 $ver"
}

if (-not (Test-Path '.\.venv-g2')) {
    python -m venv .venv-g2
}

& .\.venv-g2\Scripts\python.exe -m pip install -U pip
& .\.venv-g2\Scripts\python.exe -m pip install -r requirements-g2.txt
Write-Host 'mapgen venv ready.'
Write-Host 'Generate: .\.venv-g2\Scripts\python.exe serve_g2.py --port 8766'
Write-Host 'Tests:    .\.venv-g2\Scripts\python.exe -m pytest -q'
