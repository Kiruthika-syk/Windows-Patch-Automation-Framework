#requires -Version 7.2
<#
.SYNOPSIS
Regenerates docs/fleet-status.json from patch run output for the internal website.
#>
[CmdletBinding()]
param(
    [string]$OutputJsonPath = (Join-Path $PSScriptRoot '../docs/fleet-status.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$outputRoot = Join-Path $root 'output'
$configInventory = Join-Path $root 'config/vms.csv'

function Get-InventoryMetadata {
    param([string[]]$CsvPaths)

    $map = @{}
    foreach ($path in $CsvPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        foreach ($row in Import-Csv -LiteralPath $path) {
            $name = [string]$row.VMName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $map[$name.Trim()] = [pscustomobject]@{
                VMName = $name.Trim()
                Enabled = [string]$row.Enabled
                IPAddress = if ($row.PSObject.Properties.Name -contains 'IPAddress') { [string]$row.IPAddress } else { '' }
                FQDN = if ($row.PSObject.Properties.Name -contains 'FQDN') { [string]$row.FQDN } else { '' }
                Owner = if ($row.PSObject.Properties.Name -contains 'Owner') { [string]$row.Owner } else { '' }
                Environment = if ($row.PSObject.Properties.Name -contains 'Environment') { [string]$row.Environment } else { '' }
                Notes = if ($row.PSObject.Properties.Name -contains 'Notes') { [string]$row.Notes } else { '' }
            }
        }
    }
    $map
}

function ConvertTo-RunDateTime {
    param(
        [string]$Value,
        [datetime]$Fallback = [datetime]::MinValue
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }
    try {
        return [datetimeoffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    }
    catch {
        try {
            return [DateTime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
        catch {
            return $Fallback
        }
    }
}

function Get-StatusClass {
    param([string]$Status)
    switch ($Status) {
        'Compliant' { 'status-ok' }
        'Patching' { 'status-warn' }
        'Registered' { '' }
        'MaxCyclesExceeded' { 'status-warn' }
        default { 'status-fail' }
    }
}

function Test-EnabledInventoryRow {
    param([string]$Enabled)
    $Enabled -match '^(?i:true|yes|1)$'
}

function Resolve-InventoryVMName {
    param(
        [string]$Candidate,
        [hashtable]$InventoryMap
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $Candidate }
    $name = $Candidate.Trim()
    if ($InventoryMap.ContainsKey($name)) { return $name }

    $spaced = $name -replace '_', ' '
    if ($InventoryMap.ContainsKey($spaced)) { return $spaced }

    $compact = ($name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    foreach ($key in $InventoryMap.Keys) {
        $keyCompact = ($key -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($keyCompact -eq $compact) { return $key }
    }

    return $name
}

$inventoryPaths = @($configInventory) + @(
    Get-ChildItem -LiteralPath $outputRoot -Filter '*-only.csv' -File -ErrorAction SilentlyContinue |
        ForEach-Object FullName
)
$inventoryMap = Get-InventoryMetadata -CsvPaths $inventoryPaths

$runRecords = [System.Collections.Generic.List[object]]::new()
$inProgressRuns = [System.Collections.Generic.List[object]]::new()
$runDirs = @(Get-ChildItem -LiteralPath $outputRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[a-f0-9]{32}$' })

foreach ($runDir in $runDirs) {
    $reportPath = Join-Path $runDir.FullName 'compliance-report.json'
    $masterPath = Join-Path $runDir.FullName 'master.jsonl'
    $vmLogsRoot = Join-Path $runDir.FullName 'vm-logs'

    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $masterPath -PathType Leaf) {
            $masterItem = Get-Item -LiteralPath $masterPath
            $masterTail = @(Get-Content -LiteralPath $masterPath -Tail 30 -ErrorAction SilentlyContinue)
            $runCompleted = [bool]($masterTail -match 'Patch run completed')
            $isRecent = $masterItem.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddHours(-6)
            if (-not $runCompleted -and $isRecent) {
                $startedUtc = $masterItem.LastWriteTimeUtc.ToString('o')
                $activeVms = @()
                if (Test-Path -LiteralPath $vmLogsRoot -PathType Container) {
                    $activeVms = @(Get-ChildItem -LiteralPath $vmLogsRoot -Directory | ForEach-Object { $_.Name })
                }
                foreach ($vmName in $activeVms) {
                    $resolvedName = Resolve-InventoryVMName -Candidate $vmName -InventoryMap $inventoryMap
                    $inProgressRuns.Add([pscustomobject]@{
                            RunId = $runDir.Name
                            VMName = $resolvedName
                            Status = 'Patching'
                            StartUtc = $startedUtc
                        })
                }
            }
        }
        continue
    }

    $raw = Get-Content -LiteralPath $reportPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }

    $parsed = $raw | ConvertFrom-Json -Depth 20
    $results = @()
    if ($parsed -is [System.Array]) { $results = @($parsed) }
    elseif ($null -ne $parsed.VMName) { $results = @($parsed) }
    else { continue }

    $reportWriteUtc = (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc
    foreach ($result in $results) {
        $endUtc = ConvertTo-RunDateTime -Value ([string]$result.EndUtc) -Fallback $reportWriteUtc
        $startUtc = ConvertTo-RunDateTime -Value ([string]$result.StartUtc) -Fallback $reportWriteUtc

        $updates = @($result.Updates)
        $kbList = @($updates | ForEach-Object {
                if ($_.kbArticleIds) { ($_.kbArticleIds -join ', ') }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $resolvedVmName = Resolve-InventoryVMName -Candidate ([string]$result.VMName) -InventoryMap $inventoryMap
        $runRecords.Add([pscustomobject]@{
                RunId = $runDir.Name
                VMName = $resolvedVmName
                Status = [string]$result.Status
                Cycles = [int]$result.Cycles
                UpdatesFound = [int]$result.UpdatesFound
                UpdatesInstalled = [int]$result.UpdatesInstalled
                Reboots = [int]$result.Reboots
                StartUtc = $startUtc.ToString('o')
                EndUtc = $endUtc.ToString('o')
                SortUtc = $endUtc
                DurationSeconds = [double]$result.DurationSeconds
                ErrorMessage = [string]$result.ErrorMessage
                KBs = @($kbList | Select-Object -Unique)
                Updates = @($updates)
            })
    }
}

$orderedRuns = @($runRecords | Sort-Object SortUtc -Descending)

$latestByVm = @{}
foreach ($run in $orderedRuns) {
    $resolvedName = Resolve-InventoryVMName -Candidate $run.VMName -InventoryMap $inventoryMap
    if (-not $latestByVm.ContainsKey($resolvedName)) {
        $latestByVm[$resolvedName] = $run
        continue
    }
    $existing = $latestByVm[$resolvedName]
    if ($run.SortUtc -gt $existing.SortUtc) {
        $latestByVm[$resolvedName] = $run
    }
    elseif ($run.SortUtc -eq $existing.SortUtc -and $run.Status -eq 'Compliant' -and $existing.Status -ne 'Compliant') {
        $latestByVm[$resolvedName] = $run
    }
}

$inProgressByVm = @{}
foreach ($active in $inProgressRuns) {
    $resolvedName = Resolve-InventoryVMName -Candidate $active.VMName -InventoryMap $inventoryMap
    $inProgressByVm[$resolvedName] = $active
}

$fleetVmNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $latestByVm.Keys) { [void]$fleetVmNames.Add($name) }
foreach ($name in $inProgressByVm.Keys) { [void]$fleetVmNames.Add($name) }
foreach ($meta in $inventoryMap.Values) { [void]$fleetVmNames.Add($meta.VMName) }

$inventory = @($fleetVmNames | Sort-Object | ForEach-Object {
        $vmName = $_
        if ($inProgressByVm.ContainsKey($vmName)) {
            $active = $inProgressByVm[$vmName]
            $meta = $inventoryMap[$vmName]
            $startDisplay = if ($active.StartUtc) { ([datetime]$active.StartUtc).ToString('dd MMM yyyy HH:mm') + ' UTC' } else { 'In progress' }
            return [pscustomobject]@{
                vmName = $vmName
                ipAddress = if ($meta) { $meta.IPAddress } else { '' }
                fqdn = if ($meta) { $meta.FQDN } else { '' }
                owner = if ($meta) { $meta.Owner } else { '' }
                environment = if ($meta) { $meta.Environment } else { '' }
                enabled = if ($meta) { $meta.Enabled } else { 'false' }
                patchResult = 'Patching'
                patchStatusClass = Get-StatusClass -Status 'Patching'
                updatesInstalled = 0
                updatesFound = 0
                cycles = 0
                lastRunId = $active.RunId
                lastRunDisplay = $startDisplay
                notes = 'Patch run in progress — refresh page to see live status.'
            }
        }

        if (-not $latestByVm.ContainsKey($vmName)) {
            $meta = $inventoryMap[$vmName]
            return [pscustomobject]@{
                vmName = $vmName
                ipAddress = if ($meta) { $meta.IPAddress } else { '' }
                fqdn = if ($meta) { $meta.FQDN } else { '' }
                owner = if ($meta) { $meta.Owner } else { '' }
                environment = if ($meta) { $meta.Environment } else { '' }
                enabled = if ($meta) { $meta.Enabled } else { 'false' }
                patchResult = if ($meta -and (Test-EnabledInventoryRow -Enabled $meta.Enabled)) { 'Registered' } else { 'Not patched yet' }
                patchStatusClass = if ($meta -and (Test-EnabledInventoryRow -Enabled $meta.Enabled)) { Get-StatusClass -Status 'Registered' } else { '' }
                updatesInstalled = 0
                updatesFound = 0
                cycles = 0
                lastRunId = ''
                lastRunDisplay = 'Not started'
                notes = if ($meta -and $meta.Notes) { $meta.Notes } else { 'Awaiting first patch run.' }
            }
        }

        $_ = $latestByVm[$vmName]
        $meta = $inventoryMap[$_.VMName]
        $endDisplay = if ($_.SortUtc -gt [datetime]::MinValue) { $_.SortUtc.ToString('dd MMM yyyy HH:mm') + ' UTC' } else { 'Unknown' }
        $notes = if ($_.Status -eq 'Compliant') {
            if ($meta -and -not [string]::IsNullOrWhiteSpace($meta.Notes)) { $meta.Notes }
            else { "$($_.UpdatesInstalled) update(s) installed in $($_.Cycles) cycle(s)" }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$_.ErrorMessage)) { [string]$_.ErrorMessage }
        elseif ($meta -and $meta.Notes) { $meta.Notes }
        else { '' }

        [pscustomobject]@{
            vmName = $_.VMName
            ipAddress = if ($meta) { $meta.IPAddress } else { '' }
            fqdn = if ($meta) { $meta.FQDN } else { '' }
            owner = if ($meta) { $meta.Owner } else { '' }
            environment = if ($meta) { $meta.Environment } else { '' }
            enabled = if ($meta) { $meta.Enabled } else { 'false' }
            patchResult = $_.Status
            patchStatusClass = Get-StatusClass -Status $_.Status
            updatesInstalled = $_.UpdatesInstalled
            updatesFound = $_.UpdatesFound
            cycles = $_.Cycles
            lastRunId = $_.RunId
            lastRunDisplay = $endDisplay
            notes = $notes
        }
    } | Where-Object { $null -ne $_ })

$payload = [ordered]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    generatedAtDisplay = ([DateTime]::UtcNow).ToString('dd MMM yyyy HH:mm') + ' UTC'
    summary = [ordered]@{
        compliantVms = @($inventory | Where-Object patchResult -eq 'Compliant').Count
        patchingVms = @($inventory | Where-Object patchResult -eq 'Patching').Count
        registeredVms = @($inventory | Where-Object patchResult -eq 'Registered').Count
        trackedVms = $inventory.Count
        totalRuns = $runRecords.Count
        activeRuns = $inProgressRuns.Count
        totalUpdatesInstalled = ($runRecords | Measure-Object -Property UpdatesInstalled -Sum).Sum
    }
    inventory = $inventory
}

$jsonDir = Split-Path -Parent $OutputJsonPath
New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
$payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputJsonPath -Encoding utf8
Write-Output $OutputJsonPath
