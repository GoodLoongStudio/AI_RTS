[CmdletBinding()]
param(
    [string]$GodotExecutable,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$resultRoot = Join-Path $repositoryRoot (".test-results/performance/" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$scenePath = "res://tests/performance/PlayerVsAiPerformanceBaseline.tscn"

function Resolve-GodotConsole {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Godot executable does not exist: $resolved"
        }
        return $resolved
    }
    foreach ($environmentName in @("GODOT4", "GODOT")) {
        $environmentPath = [Environment]::GetEnvironmentVariable($environmentName)
        if (-not [string]::IsNullOrWhiteSpace($environmentPath) -and
            (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
            return [IO.Path]::GetFullPath($environmentPath)
        }
    }
    foreach ($commandName in @("godot4", "godot")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }
    $runningGodot = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like "Godot*_mono*_console" -and -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Select-Object -First 1
    if ($null -ne $runningGodot) {
        return $runningGodot.Path
    }
    $knownPath = "C:\Program Local\Godot_v4.7-stable_mono_win64\Godot_v4.7-stable_mono_win64_console.exe"
    if (Test-Path -LiteralPath $knownPath -PathType Leaf) {
        return $knownPath
    }
    throw "Godot .NET console executable was not found. Pass -GodotExecutable or set GODOT4."
}

function Format-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Format-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $stdoutPath = Join-Path $resultRoot ($Id + ".stdout.log")
    $stderrPath = Join-Path $resultRoot ($Id + ".stderr.log")
    $exitCodePath = Join-Path $resultRoot ($Id + ".exit-code.txt")
    $wrapperPath = Join-Path $resultRoot ($Id + ".process-wrapper.ps1")
    $invocation = "& " + (Format-PowerShellLiteral $FilePath) + " " +
        (@($Arguments | ForEach-Object { Format-PowerShellLiteral $_ }) -join " ")
    @(
        '$ErrorActionPreference = "Continue"',
        $invocation,
        '$capturedExitCode = $LASTEXITCODE',
        'if ($null -eq $capturedExitCode) { $capturedExitCode = 0 }',
        "[IO.File]::WriteAllText(" + (Format-PowerShellLiteral $exitCodePath) + ", [string]`$capturedExitCode)",
        'exit [int]$capturedExitCode'
    ) | Set-Content -Encoding ASCII -LiteralPath $wrapperPath

    $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File " + (Format-ProcessArgument $wrapperPath)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "[RUN ] $Id" -ForegroundColor Cyan
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentLine -WorkingDirectory $repositoryRoot `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -PassThru
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
        }
        catch {
            Write-Warning "Failed to terminate timed-out process ${Id}: $($_.Exception.Message)"
        }
        throw "$Id timed out after $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    $process.Refresh()
    $stopwatch.Stop()
    $exitCode = [int](Get-Content -Raw -Encoding ASCII -LiteralPath $exitCodePath)
    if ($exitCode -ne 0) {
        throw "$Id exited with code $exitCode. See $stdoutPath and $stderrPath."
    }
    Write-Host ("[PASS] {0} ({1:N1}s)" -f $Id, $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
    return [PSCustomObject]@{
        duration_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        stdout_path = $stdoutPath
        stderr_path = $stderrPath
    }
}

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
$sdkVersion = (& dotnet --version).Trim()
if ($LASTEXITCODE -ne 0 -or -not $sdkVersion.StartsWith("8.")) {
    throw "Resolved .NET SDK '$sdkVersion' does not satisfy required major version 8."
}
if (-not $SkipBuild) {
    Invoke-CapturedProcess "dotnet-build" "dotnet" @("build", "./OpenRTS.csproj", "--configuration", "Debug") 180 | Out-Null
}

$resolvedGodot = Resolve-GodotConsole $GodotExecutable
Write-Host "Godot console: $resolvedGodot"
$run = Invoke-CapturedProcess "player-vs-ai-baseline" $resolvedGodot `
    @("--headless", "--fixed-fps", "60", "--path", $repositoryRoot, $scenePath) 300
$stdout = Get-Content -Raw -Encoding UTF8 -LiteralPath $run.stdout_path
$stderr = Get-Content -Raw -Encoding UTF8 -LiteralPath $run.stderr_path
$combined = $stdout + [Environment]::NewLine + $stderr
$completionMarker = "Performance baseline smoke test completed: 0 failure(s)"
if (-not $combined.Contains($completionMarker)) {
    throw "Performance completion marker is missing. See $($run.stdout_path)."
}
foreach ($forbiddenPattern in @("SCRIPT ERROR", "Assertion failed", "Failed to load script")) {
    if ($combined -match $forbiddenPattern) {
        throw "Forbidden output matched '$forbiddenPattern'. See $($run.stdout_path) and $($run.stderr_path)."
    }
}
$jsonLine = @($stdout -split "`r?`n" | Where-Object { $_.StartsWith("PERFORMANCE_BASELINE_JSON: ") }) | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    throw "Performance JSON marker is missing. See $($run.stdout_path)."
}
$measurement = $jsonLine.Substring("PERFORMANCE_BASELINE_JSON: ".Length) | ConvertFrom-Json
$godotVersionLine = @($stdout -split "`r?`n" | Where-Object { $_ -like "Godot Engine *" }) | Select-Object -First 1
$commit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
$summary = [ordered]@{
    schema_version = 1
    captured_at = (Get-Date).ToUniversalTime().ToString("o")
    git_commit = $commit
    dotnet_sdk = $sdkVersion
    godot = $godotVersionLine
    os = [Environment]::OSVersion.VersionString
    processor = [Environment]::GetEnvironmentVariable("PROCESSOR_IDENTIFIER")
    logical_processor_count = [Environment]::ProcessorCount
    runner_wall_seconds = $run.duration_seconds
    measurement = $measurement
}
$summaryPath = Join-Path $resultRoot "summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
Write-Host "Performance baseline recorded: $summaryPath" -ForegroundColor Green
Write-Host ("Simulation/wall ratio: {0:N2}x; frame p95: {1:N3} ms; peak units: {2}" -f `
    $measurement.simulation_to_wall_ratio, $measurement.wall_frame_ms.p95, $measurement.peak_unit_count)
