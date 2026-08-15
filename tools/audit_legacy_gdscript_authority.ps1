[CmdletBinding()]
param(
    [string]$AllowlistPath,
    [string]$SourceRoot,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rootUri = [Uri]::new(($RepositoryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar))
    $pathUri = [Uri]::new([IO.Path]::GetFullPath($Path))
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString())
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $actual = @($Object.PSObject.Properties.Name)
    $unknown = @($actual | Where-Object { $_ -notin $Expected })
    $missing = @($Expected | Where-Object { $_ -notin $actual })
    if ($unknown.Count -gt 0 -or $missing.Count -gt 0) {
        throw "$Context schema is invalid; missing [$($missing -join ', ')], unknown [$($unknown -join ', ')]."
    }
}

function Invoke-AuthorityAudit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [string]$OverrideSourceRoot
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Allowlist does not exist: $ConfigPath"
    }

    $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigPath | ConvertFrom-Json
    Assert-ExactProperties $config @("schema_version", "scan_root", "categories") "allowlist"
    if ($config.schema_version -ne 1) {
        throw "Unsupported schema_version: $($config.schema_version)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.scan_root)) {
        throw "scan_root must not be empty."
    }
    if ($null -eq $config.categories -or @($config.categories).Count -eq 0) {
        throw "categories must not be empty."
    }

    $effectiveSourceRoot = if ([string]::IsNullOrWhiteSpace($OverrideSourceRoot)) {
        Join-Path $RepositoryRoot ([string]$config.scan_root)
    }
    else {
        [IO.Path]::GetFullPath($OverrideSourceRoot)
    }
    if (-not (Test-Path -LiteralPath $effectiveSourceRoot -PathType Container)) {
        throw "Scan root does not exist: $effectiveSourceRoot"
    }

    $seenIds = @{}
    $compiledCategories = @()
    foreach ($category in @($config.categories)) {
        Assert-ExactProperties $category @("id", "pattern", "allowed_files", "reason", "replacement_scope") "category"
        foreach ($field in @("id", "pattern", "reason", "replacement_scope")) {
            if ([string]::IsNullOrWhiteSpace([string]$category.$field)) {
                throw "category.$field must not be empty."
            }
        }
        if ($seenIds.ContainsKey([string]$category.id)) {
            throw "Duplicate category id: $($category.id)"
        }
        $seenIds[[string]$category.id] = $true

        try {
            $regex = [regex]::new([string]$category.pattern)
        }
        catch {
            throw "Category $($category.id) has an invalid pattern: $($_.Exception.Message)"
        }

        $allowed = @{}
        foreach ($relativePathValue in @($category.allowed_files)) {
            $relativePath = ([string]$relativePathValue).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.IndexOfAny(@('*', '?')) -ge 0) {
                throw "Category $($category.id) requires a non-empty exact path: $relativePath"
            }
            if ($allowed.ContainsKey($relativePath)) {
                throw "Category $($category.id) contains a duplicate path: $relativePath"
            }
            $absoluteAllowedPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativePath))
            $sourcePrefix = $effectiveSourceRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $absoluteAllowedPath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Category $($category.id) references a file outside scan_root: $relativePath"
            }
            if (-not (Test-Path -LiteralPath $absoluteAllowedPath -PathType Leaf)) {
                throw "Category $($category.id) references a missing file: $relativePath"
            }
            if ([IO.Path]::GetExtension($absoluteAllowedPath) -ne ".gd") {
                throw "Category $($category.id) references a non-GDScript file: $relativePath"
            }
            $allowed[$relativePath] = $true
        }
        $compiledCategories += [PSCustomObject]@{
            Id = [string]$category.id
            Regex = $regex
            Allowed = $allowed
        }
    }

    $files = @(Get-ChildItem -LiteralPath $effectiveSourceRoot -Recurse -File -Filter "*.gd" | Sort-Object FullName)
    $violations = @()
    $matchCount = 0
    foreach ($file in $files) {
        $relativePath = Get-NormalizedRelativePath $RepositoryRoot $file.FullName
        $lines = @(Get-Content -Encoding UTF8 -LiteralPath $file.FullName)
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if ($lines[$lineIndex].TrimStart().StartsWith("#")) {
                continue
            }
            foreach ($category in $compiledCategories) {
                if ($category.Regex.IsMatch($lines[$lineIndex])) {
                    $matchCount++
                    if (-not $category.Allowed.ContainsKey($relativePath)) {
                        $violations += [PSCustomObject]@{
                            Category = $category.Id
                            File = $relativePath
                            Line = $lineIndex + 1
                            Text = $lines[$lineIndex].Trim()
                        }
                    }
                }
            }
        }
    }

    foreach ($violation in $violations) {
        Write-Host "[FORBIDDEN] $($violation.Category) $($violation.File):$($violation.Line) $($violation.Text)" -ForegroundColor Red
    }
    if ($violations.Count -gt 0) {
        throw "Legacy GDScript authority audit failed with $($violations.Count) unregistered write(s)."
    }

    Write-Host "Legacy GDScript authority audit passed: $($files.Count) file(s), $matchCount registered match(es), no unknown bypass." -ForegroundColor Green
}

function Invoke-AuditSelfTest {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai_rts_authority_audit_" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path (Join-Path $temporaryRoot "source/allowed") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $temporaryRoot "source/unknown") -Force | Out-Null
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $temporaryRoot "source/allowed/Unit.gd") -Value "action = null"
        $testConfigPath = Join-Path $temporaryRoot "allowlist.json"
        $testConfig = @{
            schema_version = 1
            scan_root = "source"
            categories = @(
                @{
                    id = "action"
                    pattern = "\baction\s*=(?!=)"
                    allowed_files = @("source/allowed/Unit.gd")
                    reason = "self test"
                    replacement_scope = "self test"
                }
            )
        }
        $testConfig | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath $testConfigPath

        Invoke-AuthorityAudit $temporaryRoot $testConfigPath $null
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $temporaryRoot "source/unknown/Bypass.gd") -Value "action = null"
        $unknownRejected = $false
        try {
            Invoke-AuthorityAudit $temporaryRoot $testConfigPath $null
        }
        catch {
            $unknownRejected = $true
        }
        if (-not $unknownRejected) {
            throw "Self-test failed: an unknown authority write was not rejected."
        }

        $testConfig.categories[0].reason = ""
        $testConfig | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath $testConfigPath
        $invalidConfigRejected = $false
        try {
            Invoke-AuthorityAudit $temporaryRoot $testConfigPath $null
        }
        catch {
            $invalidConfigRejected = $true
        }
        if (-not $invalidConfigRejected) {
            throw "Self-test failed: an invalid allowlist was not rejected."
        }
        Write-Host "Legacy GDScript authority audit self-test passed: allowed write, unknown bypass, and invalid allowlist behaved as expected." -ForegroundColor Green
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ($SelfTest) {
    Invoke-AuditSelfTest
    exit 0
}

$effectiveAllowlistPath = if ([string]::IsNullOrWhiteSpace($AllowlistPath)) {
    Join-Path $repositoryRoot "config/legacy_gdscript_authority_allowlist.json"
}
else {
    [IO.Path]::GetFullPath($AllowlistPath)
}

try {
    Invoke-AuthorityAudit $repositoryRoot $effectiveAllowlistPath $SourceRoot
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
