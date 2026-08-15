[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$coreProjectPath = Join-Path $repositoryRoot "AI_RTS.Core.csproj"
$sourceRoots = @(
    (Join-Path $repositoryRoot "source/csharp/Domain"),
    (Join-Path $repositoryRoot "source/csharp/Application")
)
$violations = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $coreProjectPath -PathType Leaf)) {
    throw "Core project does not exist: $coreProjectPath"
}

[xml]$project = Get-Content -Raw -Encoding UTF8 -LiteralPath $coreProjectPath
$sdk = [string]$project.Project.Sdk
if ($sdk -ne "Microsoft.NET.Sdk") {
    $violations.Add("AI_RTS.Core.csproj must use Microsoft.NET.Sdk, found '$sdk'.")
}

$projectText = Get-Content -Raw -Encoding UTF8 -LiteralPath $coreProjectPath
if ($projectText -match '(?i)<PackageReference[^>]+(?:Include|Update)\s*=\s*"[^"]*Godot') {
    $violations.Add("AI_RTS.Core.csproj must not reference a Godot package.")
}
if ($projectText -match '(?i)<ProjectReference[^>]+Include\s*=\s*"[^"]*(?:OpenRTS|Godot)') {
    $violations.Add("AI_RTS.Core.csproj must not reference the Godot adapter project.")
}

$sourceFiles = @($sourceRoots | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Recurse -Filter "*.cs" -File
})
foreach ($file in $sourceFiles) {
    $relativePath = $file.FullName.Substring($repositoryRoot.Length + 1).Replace('\', '/')
    $lineNumber = 0
    foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $file.FullName) {
        $lineNumber += 1
        if ($line -match '^\s*(?:global\s+)?using\s+[^;]*\bGodot(?:\s*;|\s*\.|\s*=)' -or
            $line -match '\bGodot\s*\.') {
            $violations.Add("${relativePath}:${lineNumber}: Core source references Godot: $($line.Trim())")
        }
    }
}

if ($violations.Count -gt 0) {
    foreach ($violation in $violations) {
        Write-Error $violation
    }
    exit 1
}

Write-Host ("Core engine boundary audit passed: {0} source file(s), no Godot dependency." -f $sourceFiles.Count)
exit 0
