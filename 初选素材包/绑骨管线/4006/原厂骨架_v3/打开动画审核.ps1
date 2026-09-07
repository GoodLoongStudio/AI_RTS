$ErrorActionPreference = 'Stop'
$reviewEngine = 'G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe'
$reviewProject = Join-Path $PSScriptRoot 'godot_review'
& $reviewEngine --path $reviewProject
