$ErrorActionPreference = "Continue"
# ASCII only! PowerShell 5.1 reads .ps1 as GBK.

$stage = "G:\AIRTS\release_v4"
$7z = "C:\Program Files\7-Zip\7z.exe"

New-Item -ItemType Directory -Force -Path $stage | Out-Null

Get-Process -Name "7z*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Work from build dir so archive paths are correct:
#   Pack A -> AI_RTS_Demo.exe, data_..., *.bat, adjutant_runtime\src\
#   Pack B -> adjutant_runtime\python|ollama|models
Set-Location "g:\AIRTS\AI_RTS\build"

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
