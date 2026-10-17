param(
    [string]$Destination = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
# ASCII only! PowerShell 5.1 reads .ps1 as GBK.

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")).ProviderPath
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot "agent/manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$stage = if ($Destination) { [IO.Path]::GetFullPath($Destination) } else { $manifest.workspace_layout.packaged_delivery_root }
$sourceBuild = Join-Path $repoRoot "build"
$7z = "C:\Program Files\7-Zip\7z.exe"

if ($DryRun) {
    [PSCustomObject]@{
        source_build = $sourceBuild
        delivery_directory = $stage
        game_archive = Join-Path $stage "AI_RTS_Game_v0.4.zip"
        runtime_archive = Join-Path $stage "AI_RTS_Adjutant_Runtime.7z"
        dry_run = $true
    } | ConvertTo-Json
    return
}

New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Work from build dir so archive paths are correct:
#   Pack A -> AI_RTS_Demo.exe, data_..., *.bat, adjutant_runtime\src\
#   Pack B -> adjutant_runtime\python|ollama|models
Set-Location -LiteralPath $sourceBuild

# ================= Pack A : game (zip, repack every update) =================
Write-Host "[A] game package ..."
Get-ChildItem "$stage\AI_RTS_Game*.zip" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
& $7z a -tzip "$stage\AI_RTS_Game_v0.4.zip" `
    "AI_RTS_Demo.exe" `
    "data_OpenRTS_windows_x86_64" `
    "adjutant_runtime\src" `
    "adjutant_runtime\.env.local" `
    "*.bat" "*.txt" `
    "-mx=1" "-mcu=on" "-bso0" "-bsp0"
Write-Host ("  A -> " + [math]::Round((Get-Item "$stage\AI_RTS_Game_v0.4.zip").Length / 1MB, 1) + " MB")

# ================= Pack B : runtime heavy (7z split, upload ONCE) =================
Write-Host "[B] runtime package (this takes a while) ..."
Get-ChildItem "$stage\AI_RTS_Adjutant_Runtime.7z*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
& $7z a -t7z -v1900m "$stage\AI_RTS_Adjutant_Runtime.7z" `
    "adjutant_runtime\python" `
    "adjutant_runtime\ollama" `
    "adjutant_runtime\models" `
    "-xr!__pycache__" "-xr!*.pyc" "-mx=1" "-bso0" "-bsp0" | Out-Null

Write-Host ""
Write-Host "=== FINAL ==="
Get-ChildItem $stage -File | ForEach-Object { "  " + $_.Name + "  " + [math]::Round($_.Length / 1MB, 1) + " MB" }
$tot = (Get-ChildItem $stage -File | Measure-Object Length -Sum).Sum
Write-Host ("TOTAL: " + [math]::Round($tot / 1GB, 2) + " GB")
Write-Host "[DONE]"
