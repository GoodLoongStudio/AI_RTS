$pat = 'run_ref10_then_sweep|run_post_sweep_checks|run_training_loop_20260927|run_capture_after_loop|fs_screen_|fs_reg_|fs_ref|loop27'
$targets = Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -in @('bash.exe', 'sh.exe', 'python.exe', 'pythonw.exe')) -and
    ($_.CommandLine -match $pat)
}
foreach ($t in $targets) {
    $clip = $t.CommandLine
    if ($clip.Length -gt 120) { $clip = $clip.Substring(0, 120) }
    Write-Output ("KILL " + $t.ProcessId + " :: " + $clip)
    Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue
}
if (-not $targets) { Write-Output "no matching processes" }
