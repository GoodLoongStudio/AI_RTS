<#
build_windows.ps1 -- one-click Windows export for AI_RTS (Godot 4.7.1 .NET / Mono).

Usage:
  powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1
  powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1 -Godot "D:\Godot\Godot_v4.7.1-stable_mono_win64_console.exe" -Out "build\Open RTS.exe"

What it does:
  1) checks prerequisites: git-lfs, .NET SDK 8, Godot 4.7.1 mono editor, 4.7.1.stable.mono export templates
  2) imports project resources (first run / after big pulls)
  3) exports the "Windows Desktop" preset (single-file exe, embed_pck)
  4) prints the artifact path and size

Exit codes: 0 = success, non-zero = first failed check / export failure.
#>
param(
    [string]$Godot = "",
    [string]$Out = "build\Open RTS.exe",
    [switch]$SkipImport
)

$ErrorActionPreference = "Stop"

function Fail($msg) {
    Write-Host ""
    Write-Host "[FAIL] $msg" -ForegroundColor Red
    exit 1
}
function Ok($msg) { Write-Host "[ ok ] $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "[info] $msg" }

# ---- locate repo root (this script lives in <repo>\tools) ----
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not (Test-Path (Join-Path $repo "project.godot"))) {
    Fail "project.godot not found under '$repo'. Keep this script in <repo>\tools\."
}
Set-Location $repo
Write-Host "=== AI_RTS Windows build ==="
Info "repo: $repo"

# ---- 1. git-lfs ----
$lfs = (Get-Command git-lfs -ErrorAction SilentlyContinue)
if (-not $lfs) {
    Fail "git-lfs not found. Install it (https://git-lfs.com) and run 'git lfs install' + 'git lfs pull' in the repo."
}
Ok ("git-lfs: " + (& git lfs version))

# ---- 2. .NET SDK ----
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue)
if (-not $dotnet) {
    Fail ".NET SDK not found. Install .NET SDK 8 (https://dotnet.microsoft.com/download/dotnet/8.0)."
}
$dotnetVer = (& dotnet --version)
if ([int]($dotnetVer.Split(".")[0]) -lt 8) {
    Fail ".NET SDK $dotnetVer is too old. Need 8.x (global.json pins 8.0.100)."
}
Ok "dotnet: $dotnetVer"

# ---- 3. Godot editor (4.7.1 mono) ----
if (-not $Godot) {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:RTS_GODOT) { $cands.Add($env:RTS_GODOT) }
    if ($env:GODOT4) { $cands.Add($env:GODOT4) }
    # shallow scan: the repo itself and sibling "godot*" folders (this machine's layout)
    $parent = Split-Path -Parent $repo
    $scanRoots = @($repo)
    if ($parent -and (Test-Path $parent)) {
        Get-ChildItem -Path $parent -Directory -Filter "godot*" -ErrorAction SilentlyContinue |
            ForEach-Object { $scanRoots += $_.FullName }
    }
    foreach ($r in $scanRoots) {
        Get-ChildItem -Path $r -Filter "Godot_v*_mono_*_console.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            ForEach-Object { $cands.Add($_.FullName) }
    }
    $Godot = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $Godot -or -not (Test-Path $Godot)) {
    Fail "Godot 4.7.1 mono console exe not found. Download 'Godot_v4.7.1-stable_mono_win64' from https://godotengine.org/download/archive/4.7.1-stable/ and pass -Godot <path>."
}
$gver = (& $Godot --version) 2>$null
Ok "godot: $Godot ($gver)"
if ($gver -notmatch "^4\.7") {
    Write-Host "[warn] Godot version '$gver' does not look like 4.7.x. Project features are 4.7; use 4.7.1 mono." -ForegroundColor Yellow
}

# ---- 4. export templates ----
$tplDir = Join-Path $env:APPDATA "Godot\export_templates\4.7.1.stable.mono"
if (-not (Test-Path $tplDir)) {
    $alt = Join-Path $repo "Godot\export_templates\4.7.1.stable.mono"
    if (Test-Path $alt) { $tplDir = $alt }
}
if (-not (Test-Path $tplDir)) {
    Fail @"
Export templates 4.7.1.stable.mono not found.
Expected: $tplDir  (or <repo>\Godot\export_templates\4.7.1.stable.mono)
Download: https://godotengine.org/download/archive/4.7.1-stable/  -> mono_export_templates.tpz (~1.2GB)
Direct (follow the 302): https://downloads.godotengine.org/?version=4.7.1&flavor=stable&slug=mono_export_templates.tpz
Unpack so the folder name is exactly "4.7.1.stable.mono".
"@
}
$tplCount = (Get-ChildItem $tplDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
if ($tplCount -eq 0) { Fail "Template dir exists but is empty: $tplDir" }
Ok "export templates: $tplDir ($tplCount files)"

# ---- 5. import resources ----
if (-not $SkipImport) {
    Info "importing resources (first run can take a while) ..."
    & $Godot --headless --path $repo --import
    if ($LASTEXITCODE -ne 0) { Fail "resource import failed (exit $LASTEXITCODE)." }
    Ok "import done"
}

# ---- 6. export ----
$outPath = Join-Path $repo $Out
$outDir = Split-Path -Parent $outPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
Info "exporting 'Windows Desktop' -> $outPath"
& $Godot --headless --path $repo --export-release "Windows Desktop" $outPath
if ($LASTEXITCODE -ne 0) { Fail "export failed (exit $LASTEXITCODE). Check the log above (console build prints details)." }
if (-not (Test-Path $outPath)) { Fail "export reported success but artifact not found: $outPath" }

$size = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
Write-Host ""
Ok "BUILD OK: $outPath ($size MB)"
Info "double-click it to play; ship this single exe to players (no Godot/.NET needed on their side)."
