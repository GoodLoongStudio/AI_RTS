# 把本地图包安装进 AI_RTS（在同版本工程中执行）
param([Parameter(Mandatory=$true)][string]$AirtsRoot,
      [string]$AssetSource = 'G:/AIRTS/AI_RTS/pytest-of-Administrator/pytest-1/test_bundle_merges_visual_deps0/srcroot',
      [string]$GodotExe = '')
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$mapDir = Join-Path $AirtsRoot 'source/match/maps/generated/16-0-bundletest'
New-Item -ItemType Directory -Force -Path $mapDir | Out-Null
Copy-Item (Join-Path $src 'source/*') $mapDir -Force
$deps = Get-Content (Join-Path $src 'assets/dependencies.json') -Raw -Encoding UTF8 | ConvertFrom-Json
# 1) 运行脚本/内置贴图：从包内冻结副本安装（不取开发机/目标工程，历史包自洽）
foreach ($r in $deps.runtime_scripts) {
  $dst = Join-Path $AirtsRoot $r.install_to
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  Copy-Item (Join-Path $src $r.bundled) $dst -Force
}
# 2) 素材依赖：从 -AssetSource 安装，缺失统一收集后明确失败
$missing = @()
foreach ($d in $deps.assets) {
  $dst = Join-Path $AirtsRoot $d.install_to
  if (Test-Path $dst) { continue }
  $rel = $d.res_path -replace '^res://',''
  $found = Join-Path $AssetSource $rel
  if (-not (Test-Path $found)) { $missing += $d.res_path; continue }
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  Copy-Item $found $dst -Force
}
if ($missing.Count -gt 0) {
  Write-Error ('缺失素材依赖，安装失败（未生成可用地图）: ' + ($missing -join ', '))
  exit 1
}
# 3) 校验 terrain navmesh 配套（坡道连通需 agent_max_climb>=0.3）
$matchTscn = Join-Path $AirtsRoot 'source/match/Match.tscn'
if (Test-Path $matchTscn) {
  $txt = Get-Content $matchTscn -Raw
  $m = [regex]::Match($txt, 'terrain_navigation_input[\s\S]*?agent_max_climb\s*=\s*([0-9.]+)')
  if ($m.Success -and ([double]$m.Groups[1].Value) -lt 0.3) {
    Write-Error ('目标工程 terrain navmesh agent_max_climb=' + $m.Groups[1].Value + ' < 0.3，' +
                 '生成地图坡道无法连通。请先将 Match.tscn 中 terrain_navigation_input 所属' +
                 ' NavigationMesh 的 agent_max_climb 设为 0.5。')
    exit 1
  }
}
if ($GodotExe) {
  & $GodotExe --headless --path $AirtsRoot --import
  if ($LASTEXITCODE -ne 0) { Write-Error 'Godot 导入失败'; exit 1 }
  Write-Host '导入完成。启动游戏后在地图列表选择 Generated 16-0-bundletest。'
} else {
  Write-Host '文件已安装。请用 Godot 打开工程完成导入（或带 -GodotExe 参数重跑）。'
}