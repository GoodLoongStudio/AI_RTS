[CmdletBinding()]
param(
    [string]$GodotExecutable,
    [string[]]$TestId,
    [switch]$SkipBuild,
    [switch]$SkipCore,
    [switch]$SkipAudit,
    [switch]$SkipGodot
)

$ErrorActionPreference = "Stop"
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$manifestPath = Join-Path $repositoryRoot "config/full_regression_suite.json"
$resultRoot = Join-Path $repositoryRoot (".test-results/full-regression/" + (Get-Date -Format "yyyyMMdd-HHmmss"))

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
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$ExpectedMarker,
        [string[]]$ForbiddenPatterns = @()
    )

    $safeId = $Id -replace '[^A-Za-z0-9_.-]', '_'
    $stdoutPath = Join-Path $resultRoot ($safeId + ".stdout.log")
    $stderrPath = Join-Path $resultRoot ($safeId + ".stderr.log")
    $exitCodePath = Join-Path $resultRoot ($safeId + ".exit-code.txt")
    $wrapperPath = Join-Path $resultRoot ($safeId + ".process-wrapper.ps1")
    $invocation = "& " + (Format-PowerShellLiteral $FilePath) + " " +
        (@($Arguments | ForEach-Object { Format-PowerShellLiteral $_ }) -join " ")
    $wrapperLines = @(
        '$ErrorActionPreference = "Continue"',
        $invocation,
        '$capturedExitCode = $LASTEXITCODE',
        'if ($null -eq $capturedExitCode) { $capturedExitCode = 0 }',
        "[IO.File]::WriteAllText(" + (Format-PowerShellLiteral $exitCodePath) + ", [string]`$capturedExitCode)",
        'exit [int]$capturedExitCode'
    )
    $wrapperLines | Set-Content -Encoding ASCII -LiteralPath $wrapperPath
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
    }
    else {
        # Windows PowerShell needs a parameterless wait to flush redirected streams and ExitCode.
        $process.WaitForExit()
        $process.Refresh()
    }
    $stopwatch.Stop()

    $stdout = if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -Raw -Encoding UTF8 -LiteralPath $stdoutPath
    }
    else {
        ""
    }
    $stderr = if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -Raw -Encoding UTF8 -LiteralPath $stderrPath
    }
    else {
        ""
    }
    $combined = $stdout + [Environment]::NewLine + $stderr
    $reasons = @()
    $exitCode = if ($completed -and (Test-Path -LiteralPath $exitCodePath -PathType Leaf)) {
        [int](Get-Content -Raw -Encoding ASCII -LiteralPath $exitCodePath)
    }
    else {
        $null
    }
    if (-not $completed) {
        $reasons += "Timed out after $TimeoutSeconds seconds"
    }
    elseif ($exitCode -ne 0) {
        $reasons += "Exit code was $exitCode"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMarker) -and
        -not $combined.Contains($ExpectedMarker)) {
        $reasons += "Expected marker was missing: $ExpectedMarker"
    }
    foreach ($forbiddenPattern in @($ForbiddenPatterns)) {
        if ($combined -match $forbiddenPattern) {
            $reasons += "Forbidden output matched: $forbiddenPattern"
        }
    }

    $passed = $reasons.Count -eq 0
    if ($passed) {
        Write-Host ("[PASS] {0} ({1:N1}s)" -f $Id, $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    else {
        Write-Host ("[FAIL] {0}: {1}" -f $Id, ($reasons -join "; ")) -ForegroundColor Red
    }
    return [PSCustomObject]@{
        id = $Id
        passed = $passed
        duration_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        exit_code = $exitCode
        reasons = @($reasons)
        stdout_log = $stdoutPath.Substring($repositoryRoot.Length + 1).Replace('\', '/')
        stderr_log = $stderrPath.Substring($repositoryRoot.Length + 1).Replace('\', '/')
    }
}

function Assert-Manifest {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    if ($Manifest.schema_version -ne 1) {
        throw "Unsupported regression manifest schema_version: $($Manifest.schema_version)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.required_sdk_prefix)) {
        throw "required_sdk_prefix must not be empty."
    }
    $ids = @{}
    $scenes = @{}
    foreach ($test in @($Manifest.godot_tests)) {
        foreach ($field in @("id", "category", "scene", "expected_marker", "timeout_seconds")) {
            if ($null -eq $test.$field -or [string]::IsNullOrWhiteSpace([string]$test.$field)) {
                throw "Godot test field must not be empty: $field"
            }
        }
        if ($ids.ContainsKey([string]$test.id)) {
            throw "Duplicate Godot test id: $($test.id)"
        }
        if ($scenes.ContainsKey([string]$test.scene)) {
            throw "Duplicate Godot test scene: $($test.scene)"
        }
        if ([int]$test.timeout_seconds -lt 1) {
            throw "Godot test timeout must be positive: $($test.id)"
        }
        $scenePath = Join-Path $repositoryRoot ([string]$test.scene).Replace("res://", "")
        if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
            throw "Godot test scene does not exist: $($test.scene)"
        }
        $ids[[string]$test.id] = $true
        $scenes[[string]$test.scene] = $true
    }

    $diskScenes = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "tests/automated") -Filter "*.tscn" -File |
        ForEach-Object { "res://tests/automated/" + $_.Name })
    $unregistered = @($diskScenes | Where-Object { -not $scenes.ContainsKey($_) })
    $stale = @($scenes.Keys | Where-Object { $_ -notin $diskScenes })
    if ($unregistered.Count -gt 0 -or $stale.Count -gt 0) {
        throw "Regression manifest scene mismatch; unregistered [$($unregistered -join ', ')], stale [$($stale -join ', ')]."
    }
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Regression manifest does not exist: $manifestPath"
}
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
Assert-Manifest $manifest
$sdkVersion = (& dotnet --version).Trim()
if ($LASTEXITCODE -ne 0 -or -not $sdkVersion.StartsWith([string]$manifest.required_sdk_prefix)) {
    throw "Resolved .NET SDK '$sdkVersion' does not satisfy prefix '$($manifest.required_sdk_prefix)'."
}

$selectedTests = @($manifest.godot_tests)
$requestedIds = @($TestId | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($requestedIds.Count -gt 0) {
    $unknownIds = @($requestedIds | Where-Object { $_ -notin @($manifest.godot_tests.id) })
    if ($unknownIds.Count -gt 0) {
        throw "Unknown test id(s): $($unknownIds -join ', ')"
    }
    $selectedTests = @($selectedTests | Where-Object { $_.id -in $requestedIds })
}

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
$results = @()
if (-not $SkipBuild) {
    $results += Invoke-CapturedProcess "dotnet-build" "dotnet" `
        @("build", "./OpenRTS.csproj", "--configuration", "Debug") 180 "" @()
}
if (-not $SkipCore) {
    $results += Invoke-CapturedProcess "core-tests" "dotnet" `
        @("run", "--project", "./tests/core/AI_RTS.Core.Tests.csproj", "--configuration", "Debug") `
        180 "Match outcome tests completed: 11 test(s), 0 failure(s)." @()
}
if (-not $SkipAudit) {
    $results += Invoke-CapturedProcess "legacy-authority-audit" "powershell.exe" `
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "./tools/audit_legacy_gdscript_authority.ps1") `
        60 "Legacy GDScript authority audit passed:" @()
}
if (-not $SkipGodot) {
    $resolvedGodot = Resolve-GodotConsole $GodotExecutable
    Write-Host "Godot console: $resolvedGodot"
    foreach ($test in $selectedTests) {
        $results += Invoke-CapturedProcess ([string]$test.id) $resolvedGodot `
            @("--headless", "--path", $repositoryRoot, [string]$test.scene) `
            ([int]$test.timeout_seconds) ([string]$test.expected_marker) @($manifest.forbidden_output_patterns)
    }
}

$passedCount = @($results | Where-Object { $_.passed }).Count
$failedResults = @($results | Where-Object { -not $_.passed })
$summary = [PSCustomObject]@{
    generated_at = (Get-Date).ToString("o")
    repository = $repositoryRoot
    sdk_version = $sdkVersion
    passed = $failedResults.Count -eq 0
    passed_count = $passedCount
    failed_count = $failedResults.Count
    results = @($results)
}
$summaryPath = Join-Path $resultRoot "summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
Write-Host "Regression summary: $($summaryPath.Substring($repositoryRoot.Length + 1))"
Write-Host "Full regression completed: $passedCount passed, $($failedResults.Count) failed."
if ($failedResults.Count -gt 0) {
    exit 1
}
exit 0
