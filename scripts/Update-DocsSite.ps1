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
                    $inProgressRuns.Add([pscustomobject]@{
                            RunId = $runDir.Name
                            VMName = $vmName
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

        $runRecords.Add([pscustomobject]@{
                RunId = $runDir.Name
                VMName = [string]$result.VMName
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
    if (-not $latestByVm.ContainsKey($run.VMName)) {
        $latestByVm[$run.VMName] = $run
        continue
    }
    $existing = $latestByVm[$run.VMName]
    if ($run.SortUtc -gt $existing.SortUtc) {
        $latestByVm[$run.VMName] = $run
    }
    elseif ($run.SortUtc -eq $existing.SortUtc -and $run.Status -eq 'Compliant' -and $existing.Status -ne 'Compliant') {
        $latestByVm[$run.VMName] = $run
    }
}

$inProgressByVm = @{}
foreach ($active in $inProgressRuns) {
    $inProgressByVm[$active.VMName] = $active
}

$fleetVmNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $latestByVm.Keys) { [void]$fleetVmNames.Add($name) }
foreach ($name in $inProgressByVm.Keys) { [void]$fleetVmNames.Add($name) }
foreach ($meta in $inventoryMap.Values) {
    if (Test-EnabledInventoryRow -Enabled $meta.Enabled) {
        [void]$fleetVmNames.Add($meta.VMName)
    }
}

$fleetStatus = @($fleetVmNames | Sort-Object | ForEach-Object {
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
                status = 'Patching'
                statusClass = Get-StatusClass -Status 'Patching'
                updatesInstalled = 0
                updatesFound = 0
                cycles = 0
                lastRunId = $active.RunId
                lastRunUtc = $active.StartUtc
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
                status = 'Registered'
                statusClass = Get-StatusClass -Status 'Registered'
                updatesInstalled = 0
                updatesFound = 0
                cycles = 0
                lastRunId = ''
                lastRunUtc = $null
                lastRunDisplay = 'Not started'
                notes = if ($meta -and $meta.Notes) { $meta.Notes } else { 'Added to inventory — awaiting first patch run.' }
            }
        }

        $_ = $latestByVm[$vmName]
        $meta = $inventoryMap[$_.VMName]
        $endDisplay = if ($_.SortUtc -gt [datetime]::MinValue) { $_.SortUtc.ToString('dd MMM yyyy HH:mm') + ' UTC' } else { 'Unknown' }
        $notes = if ($meta -and -not [string]::IsNullOrWhiteSpace($meta.Notes)) { $meta.Notes }
        elseif ($_.Status -eq 'Compliant') { "Last run $($_.RunId.Substring(0, 8)) — $($_.UpdatesInstalled) installed, $($_.Cycles) cycle(s)" }
        else { [string]$_.ErrorMessage }

        [pscustomobject]@{
            vmName = $_.VMName
            ipAddress = if ($meta) { $meta.IPAddress } else { '' }
            fqdn = if ($meta) { $meta.FQDN } else { '' }
            owner = if ($meta) { $meta.Owner } else { '' }
            environment = if ($meta) { $meta.Environment } else { '' }
            status = $_.Status
            statusClass = Get-StatusClass -Status $_.Status
            updatesInstalled = $_.UpdatesInstalled
            updatesFound = $_.UpdatesFound
            cycles = $_.Cycles
            lastRunId = $_.RunId
            lastRunUtc = $_.EndUtc
            lastRunDisplay = $endDisplay
            notes = $notes
        }
    } | Where-Object { $null -ne $_ })

$runHistory = @($inProgressRuns | ForEach-Object {
        [pscustomobject]@{
            vmName = $_.VMName
            runId = $_.RunId
            date = 'In progress'
            status = 'Patching'
            statusClass = Get-StatusClass -Status 'Patching'
            installed = 0
            cycles = 0
        }
    })

$runHistory += @($orderedRuns | ForEach-Object {
        $endDisplay = if ($_.SortUtc -gt [datetime]::MinValue) { $_.SortUtc.ToString('dd MMM yyyy') } else { 'Unknown' }
        [pscustomobject]@{
            vmName = $_.VMName
            runId = $_.RunId
            date = $endDisplay
            status = $_.Status
            statusClass = Get-StatusClass -Status $_.Status
            installed = $_.UpdatesInstalled
            cycles = $_.Cycles
        }
    })
$runHistory = @($runHistory | Sort-Object {
        if ($_.status -eq 'Patching') { return [datetime]::MaxValue }
        $parsed = [datetime]::MinValue
        [void][datetime]::TryParse([string]$_.date, [ref]$parsed)
        $parsed
    } -Descending)

$inventory = @($inventoryMap.Values | Sort-Object VMName | ForEach-Object {
        $latest = $latestByVm[$_.VMName]
        [pscustomobject]@{
            vmName = $_.VMName
            ipAddress = $_.IPAddress
            enabled = $_.Enabled
            owner = $_.Owner
            fqdn = $_.FQDN
            environment = $_.Environment
            patchStatus = if ($inProgressByVm.ContainsKey($_.VMName)) { 'Patching' }
            elseif ($latest) { $latest.Status }
            elseif (Test-EnabledInventoryRow -Enabled $_.Enabled) { 'Registered' }
            else { 'Not patched yet' }
            patchStatusClass = if ($inProgressByVm.ContainsKey($_.VMName)) { Get-StatusClass -Status 'Patching' }
            elseif ($latest) { Get-StatusClass -Status $latest.Status }
            elseif (Test-EnabledInventoryRow -Enabled $_.Enabled) { Get-StatusClass -Status 'Registered' }
            else { '' }
        }
    })

$allVmsFromRuns = @($latestByVm.Keys | Sort-Object)
foreach ($vmName in $allVmsFromRuns) {
    if ($inventoryMap.ContainsKey($vmName)) { continue }
    $latest = $latestByVm[$vmName]
    $inventory += [pscustomobject]@{
        vmName = $vmName
        ipAddress = ''
        enabled = 'false'
        owner = ''
        fqdn = ''
        environment = ''
        patchStatus = $latest.Status
        patchStatusClass = Get-StatusClass -Status $latest.Status
    }
}
$inventory = @($inventory | Sort-Object vmName)

$recentUpdates = [System.Collections.Generic.List[object]]::new()
foreach ($run in ($orderedRuns | Select-Object -First 20)) {
    foreach ($update in @($run.Updates)) {
        if ($update.result -notin 'Succeeded', 'SucceededWithErrors') { continue }
        $kb = if ($update.kbArticleIds) { ($update.kbArticleIds -join ', ') } else { '' }
        $recentUpdates.Add([pscustomobject]@{
                vmName = $run.VMName
                kb = $kb
                title = [string]$update.title
                runId = $run.RunId
                date = if ($run.SortUtc -gt [datetime]::MinValue) { $run.SortUtc.ToString('dd MMM yyyy') } else { '' }
            })
    }
}

$payload = [ordered]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    generatedAtDisplay = ([DateTime]::UtcNow).ToString('dd MMM yyyy HH:mm') + ' UTC'
    summary = [ordered]@{
        compliantVms = @($fleetStatus | Where-Object status -eq 'Compliant').Count
        patchingVms = @($fleetStatus | Where-Object status -eq 'Patching').Count
        registeredVms = @($fleetStatus | Where-Object status -eq 'Registered').Count
        trackedVms = $fleetStatus.Count
        totalRuns = $runRecords.Count
        activeRuns = $inProgressRuns.Count
        totalUpdatesInstalled = ($runRecords | Measure-Object -Property UpdatesInstalled -Sum).Sum
    }
    fleetStatus = $fleetStatus
    runHistory = $runHistory
    inventory = $inventory
    recentUpdates = @($recentUpdates | Select-Object -First 50)
}

$jsonDir = Split-Path -Parent $OutputJsonPath
New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
$payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputJsonPath -Encoding utf8
Write-Output $OutputJsonPath
