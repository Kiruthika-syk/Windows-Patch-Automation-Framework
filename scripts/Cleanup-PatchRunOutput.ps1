#requires -Version 7.0
<#
.SYNOPSIS
Removes completed patch run output folders and related logs after a retention period.

.DESCRIPTION
Deletes output/<run-id>/ directories only after the run has finished (compliance report
or master log shows completion) and EndUtc is older than the retention window.
In-progress runs are never deleted.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'output'),
    [ValidateRange(1, 8760)][int]$RetentionHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:PATCH_OUTPUT_RETENTION_HOURS) {
    $RetentionHours = [int]$env:PATCH_OUTPUT_RETENTION_HOURS
}

$cutoff = (Get-Date).ToUniversalTime().AddHours(-$RetentionHours)
$runIdPattern = '^[0-9a-f]{32}$'
$removedRuns = @()
$skippedActive = @()

function Get-RunCompletionUtc {
    param([Parameter(Mandatory)][string]$RunDirectory)

    $compliancePath = Join-Path $RunDirectory 'compliance-report.csv'
    if (Test-Path -LiteralPath $compliancePath) {
        $rows = Import-Csv -LiteralPath $compliancePath
        $endValues = @($rows | ForEach-Object { $_.EndUtc } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($endValues.Count -gt 0) {
            $latest = $endValues | ForEach-Object { ([datetimeoffset]::Parse($_)).UtcDateTime } | Sort-Object -Descending | Select-Object -First 1
            return $latest
        }
    }

    $masterPath = Join-Path $RunDirectory 'master.jsonl'
    if (-not (Test-Path -LiteralPath $masterPath)) {
        return $null
    }

    $completedLine = Get-Content -LiteralPath $masterPath -ErrorAction SilentlyContinue |
        Where-Object { $_ -match 'Patch run completed\.' } |
        Select-Object -Last 1

    if (-not $completedLine) {
        return $null
    }

    try {
        $parsed = $completedLine | ConvertFrom-Json
        return ([datetimeoffset]::Parse([string]$parsed.timestampUtc)).UtcDateTime
    }
    catch {
        return $null
    }
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    Write-Host "Output path not found: $OutputPath"
    exit 0
}

Get-ChildItem -LiteralPath $OutputPath -Directory | ForEach-Object {
    if ($_.Name -notmatch $runIdPattern) {
        return
    }

    $completionUtc = Get-RunCompletionUtc -RunDirectory $_.FullName
    if (-not $completionUtc) {
        $latestActivity = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1).LastWriteTimeUtc

        if ($latestActivity -gt $cutoff) {
            $skippedActive += $_.Name
            return
        }

        if ($PSCmdlet.ShouldProcess($_.FullName, "Remove abandoned patch run output inactive for $RetentionHours hours")) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
            $removedRuns += $_.Name
        }
        return
    }

    if ($completionUtc -gt $cutoff) {
        return
    }

    if ($PSCmdlet.ShouldProcess($_.FullName, "Remove completed patch run output older than $RetentionHours hours")) {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
        $removedRuns += $_.Name
    }
}

$logPatterns = @('*-patch.log', '*-repatch.log', 'patch-run*.log')
Get-ChildItem -LiteralPath $OutputPath -File | ForEach-Object {
    $file = $_
    $isPatchLog = $false
    foreach ($pattern in $logPatterns) {
        if ($file.Name -like $pattern) {
            $isPatchLog = $true
            break
        }
    }
    if (-not $isPatchLog) {
        return
    }

    if ($file.LastWriteTimeUtc -gt $cutoff) {
        return
    }

    if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove stale patch log file')) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
}

$validationPath = Join-Path $OutputPath 'validation'
if (Test-Path -LiteralPath $validationPath) {
    Get-ChildItem -LiteralPath $validationPath -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LastWriteTimeUtc -gt $cutoff) {
            return
        }

        if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove stale validation artifact')) {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }
}

Write-Host "Patch output cleanup (retention: ${RetentionHours}h, cutoff UTC: $($cutoff.ToString('o')))"
if ($removedRuns.Count -gt 0) {
    Write-Host "Removed run folders: $($removedRuns -join ', ')"
}
else {
    Write-Host 'Removed run folders: none'
}

if ($skippedActive.Count -gt 0) {
    Write-Host "Skipped in-progress runs: $($skippedActive -join ', ')"
}
