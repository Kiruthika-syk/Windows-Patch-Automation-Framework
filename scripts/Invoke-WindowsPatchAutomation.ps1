#requires -Version 7.2
<#
.SYNOPSIS
Orchestrates convergent Windows patching through VMware Guest Operations.

.NOTES
All guest interaction is performed by PowerCLI Guest Operations cmdlets:
Invoke-VMScript and Copy-VMGuestFile. No network connection from the runner to
Windows management ports is required or used.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $PSScriptRoot '../config/settings.json'),
    [string]$InventoryPath = (Join-Path $PSScriptRoot '../config/vms.csv'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../output'),
    [switch]$FailOnNonCompliance
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$commonModule = Join-Path $PSScriptRoot 'Modules/Framework.Common.psm1'
$guestOpsModule = Join-Path $PSScriptRoot 'Modules/VCenter.GuestOps.psm1'
$guestPatchScript = Join-Path $PSScriptRoot 'Guest/Invoke-WindowsUpdate.ps1'
Import-Module $commonModule -Force

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw 'VMware.PowerCLI is required. Install the version pinned by the GitHub Actions workflow.'
}
if (-not (Test-Path -LiteralPath $guestPatchScript -PathType Leaf)) {
    throw "Guest patch script not found: $guestPatchScript"
}

$configuration = Import-FrameworkConfiguration -SettingsPath $SettingsPath -InventoryPath $InventoryPath
$settings = $configuration.Settings
$inventory = @($configuration.Inventory)
Assert-FrameworkSettings -Settings $settings

$vCenterUser = Get-RequiredEnvironmentVariable -Name 'VCENTER_USERNAME'
$vCenterPassword = Get-RequiredEnvironmentVariable -Name 'VCENTER_PASSWORD'
$guestUser = Get-RequiredEnvironmentVariable -Name 'WINDOWS_GUEST_USERNAME'
$guestPassword = Get-RequiredEnvironmentVariable -Name 'WINDOWS_GUEST_PASSWORD'
$vCenterCredential = [pscredential]::new($vCenterUser, (ConvertTo-SecureString $vCenterPassword -AsPlainText -Force))
$guestCredential = [pscredential]::new($guestUser, (ConvertTo-SecureString $guestPassword -AsPlainText -Force))

# Avoid retaining plaintext secret strings beyond credential construction.
$vCenterPassword = $null
$guestPassword = $null
[GC]::Collect()

$runId = if ($env:GITHUB_RUN_ID) { "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)" } else { [guid]::NewGuid().ToString('N') }
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $runId
$vmLogsDirectory = Join-Path $runDirectory 'vm-logs'
New-Item -ItemType Directory -Path $vmLogsDirectory -Force | Out-Null
$masterLog = Join-Path $runDirectory 'master.jsonl'
Write-StructuredLog -Path $masterLog -Level Information -Stage Run -Message 'Patch run started.' -Data @{
    runId = $runId
    vmCount = $inventory.Count
    throttleLimit = [int]$settings.throttleLimit
    maxPatchCycles = [int]$settings.maxPatchCycles
}

$workerResults = @($inventory | ForEach-Object -ThrottleLimit ([int]$settings.throttleLimit) -Parallel {
    $row = $_
    Import-Module $using:commonModule -Force
    Import-Module $using:guestOpsModule -Force

    $workerSettings = $using:settings
    $workerVCenterCredential = $using:vCenterCredential
    $workerGuestCredential = $using:guestCredential
    $vmName = $row.VMName.Trim()
    $inventoryIp = if ($row.PSObject.Properties.Name -contains 'IPAddress') { [string]$row.IPAddress.Trim() } else { '' }
    $safeVMName = $vmName -replace '[^\w.-]', '_'
    $localVMDirectory = Join-Path $using:vmLogsDirectory $safeVMName
    New-Item -ItemType Directory -Path $localVMDirectory -Force | Out-Null
    $vmLog = Join-Path $localVMDirectory 'orchestrator.jsonl'
    $started = [DateTime]::UtcNow
    $stage = 'Initialize'
    $connected = $false
    $viServer = $null
    $completedConvergence = $false
    $totalFound = 0
    $totalInstalled = 0
    $reboots = 0
    $cycles = 0
    $allUpdates = [Collections.Generic.List[object]]::new()
    $status = 'Failed'
    $errorMessage = $null
    $errorType = $null

    $logRetry = {
        param($attempt, $retryError)
        Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
            -Message 'Retrying failed operation.' -Data @{
                attempt = $attempt
                error = $retryError.Exception.Message
            }
    }

    try {
        Write-StructuredLog -Path $vmLog -Level Information -Stage Initialize -VMName $vmName -Message 'VM worker started.'
        $stage = 'ConnectVCenter'
        $hasServerOverride = $row.PSObject.Properties.Name -contains 'VCenterServer'
        $server = if ($hasServerOverride -and -not [string]::IsNullOrWhiteSpace($row.VCenterServer)) {
            $row.VCenterServer
        }
        else {
            $workerSettings.vCenterServer
        }
        $viServer = Invoke-WithRetry -Operation {
            Connect-PatchVCenter -Server $server -Credential $workerVCenterCredential `
                -IgnoreInvalidCertificate ([bool]$workerSettings.ignoreInvalidCertificate) `
                -WebOperationTimeoutSeconds ([int]$workerSettings.timeouts.webOperationSeconds)
        } -OperationName "Connect to vCenter '$server'" -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        $connected = $true

        $stage = 'ValidateVM'
        $vm = Invoke-WithRetry -Operation { Get-UniquePatchVM -VMName $vmName -Server $viServer -IPAddress $inventoryIp } -OperationName "Find VM '$vmName'" `
            -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        if ($vm.PowerState -ne 'PoweredOn') {
            throw "VM '$vmName' is '$($vm.PowerState)'; PoweredOn is required."
        }

        $stage = 'WaitForTools'
        Wait-VMToolsReady -VM $vm -Server $viServer -TimeoutSeconds ([int]$workerSettings.timeouts.toolsReadySeconds) `
            -PollSeconds ([int]$workerSettings.pollIntervalSeconds)
        Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
            -Message 'VM exists and VMware Tools is ready.'

        $stage = 'StageGuestScript'
        $guestDirectory = $workerSettings.guestWorkingDirectory
        $guestScriptPath = "$($guestDirectory.TrimEnd('\', '/'))\Invoke-WindowsUpdate.ps1"
        Invoke-WithRetry -Operation {
            Initialize-GuestPatchWorkspace -VM $vm -GuestCredential $workerGuestCredential -GuestWorkingDirectory $guestDirectory
            Copy-PatchScriptToGuest -VM $vm -GuestCredential $workerGuestCredential `
                -Source $using:guestPatchScript -Destination $guestScriptPath
        } -OperationName 'Stage guest patch script' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry

        for ($cycle = 1; $cycle -le [int]$workerSettings.maxPatchCycles; $cycle++) {
            $cycles = $cycle
            $stage = 'PatchCycle'
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message "Starting patch cycle $cycle."

            $cycleHandle = Invoke-WithRetry -Operation {
                Start-GuestPatchCycle -VM $vm -GuestCredential $workerGuestCredential `
                    -GuestScriptPath $guestScriptPath -GuestWorkingDirectory $guestDirectory `
                    -SearchCriteria $workerSettings.windowsUpdateSearchCriteria -Cycle $cycle
            } -OperationName "Start patch cycle $cycle" -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
                -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry

            Wait-GuestPatchCycle -VM $vm -GuestCredential $workerGuestCredential -CycleHandle $cycleHandle `
                -TimeoutSeconds ([int]$workerSettings.timeouts.patchCycleSeconds) `
                -PollSeconds ([int]$workerSettings.pollIntervalSeconds)

            $cycleResult = Invoke-WithRetry -Operation {
                Copy-GuestPatchArtifacts -VM $vm -GuestCredential $workerGuestCredential -CycleHandle $cycleHandle `
                    -LocalDirectory $localVMDirectory -Cycle $cycle
            } -OperationName "Collect patch cycle $cycle artifacts" -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
                -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry

            $totalFound += [int]$cycleResult.applicableCount
            $totalInstalled += [int]$cycleResult.installedCount
            foreach ($update in @($cycleResult.updates)) { $allUpdates.Add($update) }
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message "Patch cycle $cycle completed." -Data @{
                    status = $cycleResult.status
                    applicable = [int]$cycleResult.applicableCount
                    installed = [int]$cycleResult.installedCount
                    rebootRequired = [bool]$cycleResult.rebootRequired
                }

            if ($cycleResult.status -eq 'Failed') {
                $guestError = if ($cycleResult.error) { $cycleResult.error.message } else { 'Unknown guest patch error.' }
                throw "Guest patch cycle failed: $guestError"
            }
            if ($cycleResult.status -eq 'NoUpdates') {
                $status = 'Compliant'
                $completedConvergence = $true
                break
            }
            if ($cycleResult.status -eq 'RebootRequired' -or [bool]$cycleResult.rebootRequired) {
                if (-not [bool]$workerSettings.autoRebootWhenRequired) {
                    throw "Updates require a reboot but autoRebootWhenRequired is disabled for '$vmName'."
                }
                $stage = 'Reboot'
                $reboots++
                Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                    -Message 'Restarting guest after update installation.'
                Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                    -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                    -PollSeconds ([int]$workerSettings.pollIntervalSeconds)
            }
        }

        if (-not $completedConvergence) {
            $stage = 'Convergence'
            $status = 'MaxCyclesExceeded'
            throw "Applicable updates remain after the safety cap of $($workerSettings.maxPatchCycles) cycles."
        }
    }
    catch {
        if ($status -ne 'MaxCyclesExceeded') { $status = 'Failed' }
        $errorMessage = $_.Exception.Message
        $errorType = $_.Exception.GetType().FullName
        Write-StructuredLog -Path $vmLog -Level Error -Stage $stage -VMName $vmName -Message $errorMessage `
            -Data @{ type = $errorType; fullyQualifiedErrorId = $_.FullyQualifiedErrorId }
    }
    finally {
        if ($connected) {
            try { Disconnect-VIServer -Server $viServer -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }

    $ended = [DateTime]::UtcNow
    [pscustomobject]@{
        VMName = $vmName
        Status = $status
        Cycles = $cycles
        UpdatesFound = $totalFound
        UpdatesInstalled = $totalInstalled
        Reboots = $reboots
        StartUtc = $started.ToString('o')
        EndUtc = $ended.ToString('o')
        DurationSeconds = [Math]::Round(($ended - $started).TotalSeconds, 2)
        ErrorStage = if ($errorMessage) { $stage } else { $null }
        ErrorType = $errorType
        ErrorMessage = $errorMessage
        Updates = @($allUpdates)
        LogDirectory = $localVMDirectory
    }
})

$reports = Export-ComplianceReports -Results $workerResults -OutputDirectory $runDirectory

# Build a deterministic master JSONL log from the run envelope and isolated VM logs.
$vmLogFiles = @(Get-ChildItem -LiteralPath $vmLogsDirectory -Filter '*.jsonl' -File -Recurse | Sort-Object FullName)
foreach ($vmLogFile in $vmLogFiles) {
    Get-Content -LiteralPath $vmLogFile.FullName | Add-Content -LiteralPath $masterLog -Encoding utf8
}
$compliantCount = @($workerResults | Where-Object Status -eq 'Compliant').Count
$failedCount = $workerResults.Count - $compliantCount
Write-StructuredLog -Path $masterLog -Level Information -Stage Run -Message 'Patch run completed.' -Data @{
    total = $workerResults.Count
    compliant = $compliantCount
    nonCompliant = $failedCount
    reportDirectory = $runDirectory
}

$summary = @"
## Windows Patch Automation

| Result | Count |
|---|---:|
| Total VMs | $($workerResults.Count) |
| Compliant | $compliantCount |
| Failed / non-compliant | $failedCount |

Run ID: ``$runId``  
Reports: ``$runDirectory``

### VM results

| VM | Status | Cycles | Installed | Reboots | Error stage |
|---|---|---:|---:|---:|---|
$($workerResults | Sort-Object VMName | ForEach-Object {
    "| $($_.VMName.Replace('|','\|')) | $($_.Status) | $($_.Cycles) | $($_.UpdatesInstalled) | $($_.Reboots) | $($_.ErrorStage) |"
} | Out-String)
"@

if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
else {
    $summary | Set-Content -LiteralPath (Join-Path $runDirectory 'github-summary.md') -Encoding utf8
}

Write-Output "Reports generated: $($reports.Json), $($reports.Csv), $($reports.Html)"
if ($FailOnNonCompliance -and $failedCount -gt 0) {
    throw "$failedCount VM(s) failed or did not converge. Reports were generated in '$runDirectory'."
}
