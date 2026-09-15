$cursor = Get-Item $PSScriptRoot
$projectRoot = $null
while ($null -ne $cursor) {
    if (Test-Path (Join-Path $cursor.FullName 'project.godot')) {
        $projectRoot = $cursor.FullName
        break
    }
    $cursor = $cursor.Parent
}
if (-not $projectRoot) {
    throw '找不到带 project.godot 的 AI_RTS 工程根。'
}

$godotPath = $env:RTSMAP_GODOT
if (-not $godotPath) {
    $godotPath = (Get-Command '*mono*_console.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
if (-not $godotPath) {
    $godotPath = (Get-Command '*mono*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
if (-not $godotPath) {
    throw '找不到 Godot Mono。请设置 RTSMAP_GODOT 或把 *mono*_console.exe 放进 PATH。'
}

Start-Process -FilePath $godotPath -ArgumentList @(
    '--path', $projectRoot,
    '--script', 'res://tools/godot/showcase_scale_viewer.gd',
    '--rendering-method', 'gl_compatibility'
) -WindowStyle Hidden
