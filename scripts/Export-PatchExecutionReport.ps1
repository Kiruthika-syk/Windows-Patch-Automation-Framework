#requires -Version 7.2
<#
.SYNOPSIS
Exports a detailed Excel patch execution report from a completed run directory.

.DESCRIPTION
Builds the operations report requested by stakeholders:
Machine Name, guest access success, available updates, installed updates,
reboot status, and final result/reason.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunDirectory,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw "Run directory not found: $RunDirectory"
}

$jsonReport = Join-Path $RunDirectory 'compliance-report.json'
if (-not (Test-Path -LiteralPath $jsonReport -PathType Leaf)) {
    throw "Missing compliance-report.json in $RunDirectory"
}

$results = @(Get-Content -LiteralPath $jsonReport -Raw | ConvertFrom-Json -Depth 20)
if ($results.Count -eq 0) {
    throw 'No VM results found in compliance-report.json'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $RunDirectory 'Windows-Patch-Execution-Report.xlsx'
}

function Get-CycleDetails {
    param([string]$VmLogDirectory)
    $available = [System.Collections.Generic.List[string]]::new()
    $installed = [System.Collections.Generic.List[string]]::new()
    $rebootRequired = $false
    $rebootExecuted = $false
    $cycles = 0

    if (-not (Test-Path -LiteralPath $VmLogDirectory -PathType Container)) {
        return [pscustomobject]@{
            Available = @()
            Installed = @()
            RebootRequired = $false
            RebootExecuted = $false
            Cycles = 0
        }
    }

    $resultFiles = @(Get-ChildItem -LiteralPath $VmLogDirectory -Filter 'cycle-*-result.json' -File | Sort-Object Name)
    foreach ($file in $resultFiles) {
        $cycles++
        $cycle = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 20
        if ($cycle.applicableCount -gt 0) {
            foreach ($u in @($cycle.updates)) {
                $title = if ($u.title) { $u.title } else { 'Unknown update' }
                $kb = if ($u.kbArticleIds) { ($u.kbArticleIds -join ', ') } else { '' }
                $available.Add("$title $kb".Trim())
            }
        }
        elseif ($cycle.status -eq 'NoUpdates') {
            $available.Add('No applicable updates at scan time')
        }
        foreach ($u in @($cycle.updates)) {
            if ($u.result -in 'Succeeded', 'SucceededWithErrors') {
                $title = if ($u.title) { $u.title } else { 'Unknown update' }
                $kb = if ($u.kbArticleIds) { ($u.kbArticleIds -join ', ') } else { '' }
                $installed.Add("$title $kb".Trim())
            }
        }
        if ([bool]$cycle.rebootRequired) { $rebootRequired = $true }
    }

    $orchLog = Join-Path $VmLogDirectory 'orchestrator.jsonl'
    if (Test-Path -LiteralPath $orchLog -PathType Leaf) {
        $rebootExecuted = [bool](Select-String -LiteralPath $orchLog -Pattern '"stage"\s*:\s*"Reboot"' -Quiet)
    }

    [pscustomobject]@{
        Available = @($available | Select-Object -Unique)
        Installed = @($installed | Select-Object -Unique)
        RebootRequired = $rebootRequired
        RebootExecuted = $rebootExecuted
        Cycles = $cycles
    }
}

$rows = @()
foreach ($result in $results) {
    $vmLog = [string]$result.LogDirectory
    $details = Get-CycleDetails -VmLogDirectory $vmLog
    $guestAccess = if ($result.Status -eq 'Failed' -and $result.ErrorStage -in 'ConnectVCenter', 'ValidateVM', 'WaitForTools', 'StageGuestScript') {
        'No'
    }
    elseif ($result.Status -eq 'Failed') { 'Partial' }
    else { 'Yes' }

    $reason = switch ($result.Status) {
        'Compliant' { 'All applicable updates installed; no updates remain.' }
        'MaxCyclesExceeded' { "Updates remained after max cycles. $($result.ErrorMessage)" }
        'Failed' { if ($result.ErrorMessage) { $result.ErrorMessage } else { 'Patch run failed.' } }
        default { [string]$result.ErrorMessage }
    }

    $rows += [pscustomobject]@{
        MachineName = $result.VMName
        IPAddress = ''
        FQDN = ''
        VCenter = ''
        GuestAccessMethod = 'VMware Guest Operations (not RDP)'
        GuestAccessSucceeded = $guestAccess
        AvailableUpdates = ($details.Available -join '; ')
        InstalledUpdates = ($details.Installed -join '; ')
        RebootRequired = if ($details.RebootRequired) { 'Yes' } else { 'No' }
        RebootExecuted = if ($details.RebootExecuted) { 'Yes' } else { 'No' }
        PatchCycles = [int]$result.Cycles
        FinalStatus = [string]$result.Status
        ResultReason = $reason
    }
}

$excelModule = Get-Module -ListAvailable -Name ImportExcel
if ($excelModule) {
    Import-Module ImportExcel -ErrorAction Stop
    $rows | Export-Excel -Path $OutputPath -WorksheetName 'Patch Execution Report' -AutoSize -BoldTopRow -FreezeTopRow
}
else {
    $csvPath = [System.IO.Path]::ChangeExtension($OutputPath, '.csv')
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    throw "ImportExcel module not installed. CSV exported to $csvPath. Install-Module ImportExcel -Scope CurrentUser"
}

Write-Output $OutputPath
