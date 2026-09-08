#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Runs one native Windows Update Agent cycle inside a Windows guest.

.DESCRIPTION
This script deliberately has no dependency on PSWindowsUpdate or remote-management
protocols. The orchestrator copies it through VMware Guest Operations and launches
it locally in the guest. It scans, accepts update EULAs, downloads, and installs one
cycle, then writes machine-readable result and JSON Lines log files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 100)][int]$Cycle,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$LogPath,
    [string]$SearchCriteria = "IsInstalled=0 and IsHidden=0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow

function Write-GuestLog {
    param(
        [Parameter(Mandatory)][ValidateSet('Information', 'Warning', 'Error')][string]$Level,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data = @{}
    )
    $parent = Split-Path -Parent $LogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        stage = $Stage
        cycle = $Cycle
        computerName = $env:COMPUTERNAME
        message = $Message
        data = $Data
    } | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $LogPath -Encoding utf8
}

function Get-OperationResultName {
    param([int]$Code)
    switch ($Code) {
        0 { 'NotStarted' }
        1 { 'InProgress' }
        2 { 'Succeeded' }
        3 { 'SucceededWithErrors' }
        4 { 'Failed' }
        5 { 'Aborted' }
        default { "Unknown($Code)" }
    }
}

function Test-WindowsUpdateComError {
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $message = @(
        $ErrorRecord.Exception.Message
        $ErrorRecord.FullyQualifiedErrorId
    ) -join ' '
    return $message -match '(?i)800703fa|8007041d|80040154|80070005|Microsoft\.Update\.(Session|SystemInfo)|COM class factory|marked for deletion|NoCOMClassIdentified|CimException|GetCimInstanceCommand'
}

function Set-WindowsUpdateServiceState {
    param(
        [Parameter(Mandatory)][ValidateSet('Stop', 'Start')][string]$Action,
        [string[]]$ServiceNames = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
    )

    foreach ($serviceName in $ServiceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) { continue }
        if ($Action -eq 'Stop' -and $service.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        }
        if ($Action -eq 'Start' -and $service.Status -ne 'Running') {
            Set-Service -Name $serviceName -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service -Name $serviceName -ErrorAction SilentlyContinue
        }
    }
}

function Repair-WindowsUpdateAgent {
    Write-GuestLog -Level Warning -Stage Remediation -Message 'Repairing Windows Update Agent after COM failure.'

    Set-WindowsUpdateServiceState -Action Stop
    Start-Sleep -Seconds 5

    $distributionPath = Join-Path $env:SystemRoot 'SoftwareDistribution'
    if (Test-Path -LiteralPath $distributionPath) {
        $backupName = "SoftwareDistribution.old-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        $backupPath = Join-Path (Split-Path -Parent $distributionPath) $backupName
        try {
            Rename-Item -LiteralPath $distributionPath -NewName $backupName -ErrorAction Stop
            Write-GuestLog -Level Information -Stage Remediation -Message 'Renamed SoftwareDistribution cache.' -Data @{
                backupPath = $backupPath
            }
        }
        catch {
            Write-GuestLog -Level Warning -Stage Remediation -Message 'Could not rename SoftwareDistribution cache; continuing with service restart.' -Data @{
                error = $_.Exception.Message
            }
        }
    }

    Set-WindowsUpdateServiceState -Action Start
    Start-Sleep -Seconds 15
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-GuestLog -Level Information -Stage Remediation -Message 'Windows Update Agent remediation completed.'
}

function Initialize-WindowsUpdateEnvironment {
    try {
        $lastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        $bootAgeMinutes = (New-TimeSpan -Start $lastBoot -End (Get-Date)).TotalMinutes
        if ($bootAgeMinutes -lt 20) {
            Write-GuestLog -Level Information -Stage Initialize -Message 'Recent reboot detected; warming up Windows Update services.' -Data @{
                bootAgeMinutes = [Math]::Round($bootAgeMinutes, 2)
            }
            Set-WindowsUpdateServiceState -Action Start
            Start-Sleep -Seconds 45
        }
    }
    catch {
        if (Test-WindowsUpdateComError -ErrorRecord $_) {
            Write-GuestLog -Level Warning -Stage Initialize -Message 'Skipped boot warm-up because the guest OS has pending registry deletion state.'
            return
        }
        throw
    }
}

function New-WindowsUpdateSession {
    param(
        [ValidateRange(1, 3)][int]$MaxAttempts = 2
    )

    $remediationApplied = $false
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSession.ClientApplicationID = 'Enterprise Windows Patch Automation Framework'
            $systemInformation = New-Object -ComObject Microsoft.Update.SystemInfo
            return [pscustomobject]@{
                Session = $updateSession
                SystemInfo = $systemInformation
                RemediationApplied = $remediationApplied
            }
        }
        catch {
            $isComError = Test-WindowsUpdateComError -ErrorRecord $_
            if (-not $isComError -or $attempt -eq $MaxAttempts) { throw }
            Repair-WindowsUpdateAgent
            $remediationApplied = $true
        }
    }

    throw 'Unable to create Windows Update COM session.'
}

$result = [ordered]@{
    schemaVersion = '1.0'
    computerName = $env:COMPUTERNAME
    cycle = $Cycle
    status = 'Failed'
    searchCriteria = $SearchCriteria
    startedUtc = $started.ToString('o')
    completedUtc = $null
    durationSeconds = 0
    applicableCount = 0
    downloadedCount = 0
    installedCount = 0
    failedCount = 0
    rebootRequired = $false
    remediationApplied = $false
    updates = @()
    error = $null
}

try {
    Write-GuestLog -Level Information -Stage Initialize -Message 'Starting Windows Update cycle.'
    try {
        Initialize-WindowsUpdateEnvironment
    }
    catch {
        if (-not (Test-WindowsUpdateComError -ErrorRecord $_)) { throw }
        Write-GuestLog -Level Warning -Stage Initialize -Message 'Initialize warm-up failed due to pending registry deletion; continuing with remediation-aware session startup.'
    }

    $sessionContext = $null
    try {
        $sessionContext = New-WindowsUpdateSession
    }
    catch {
        if (Test-WindowsUpdateComError -ErrorRecord $_) {
            Repair-WindowsUpdateAgent
            $result.remediationApplied = $true
            $result.rebootRequired = $true
            $result.status = 'RebootRequired'
            Write-GuestLog -Level Warning -Stage Remediation -Message 'Windows Update COM still unavailable after remediation; reboot is required before retrying.'
            return
        }
        throw
    }

    $result.remediationApplied = [bool]$sessionContext.RemediationApplied
    $updateSession = $sessionContext.Session
    $systemInformation = $sessionContext.SystemInfo

    Write-GuestLog -Level Information -Stage Scan -Message 'Scanning Windows Update Agent.' -Data @{
        criteria = $SearchCriteria
    }
    $searcher = $updateSession.CreateUpdateSearcher()
    $searchResult = $searcher.Search($SearchCriteria)
    $result.applicableCount = $searchResult.Updates.Count

    if ($searchResult.Updates.Count -eq 0) {
        $result.rebootRequired = [bool]$systemInformation.RebootRequired
        if ($result.rebootRequired) {
            $result.status = 'RebootRequired'
            Write-GuestLog -Level Information -Stage Scan -Message 'No updates found, but Windows reports a pending reboot.'
        }
        else {
            $result.status = 'NoUpdates'
            Write-GuestLog -Level Information -Stage Scan -Message 'No applicable updates remain.'
        }
    }
    else {
        $downloadCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $searchResult.Updates) {
            if (-not $update.EulaAccepted) {
                $update.AcceptEula()
                Write-GuestLog -Level Information -Stage Eula -Message 'Accepted update EULA.' -Data @{
                    title = $update.Title
                }
            }
            [void]$downloadCollection.Add($update)
        }

        Write-GuestLog -Level Information -Stage Download -Message 'Downloading applicable updates.' -Data @{
            count = $downloadCollection.Count
        }
        $downloader = $updateSession.CreateUpdateDownloader()
        $downloader.Updates = $downloadCollection
        $downloadResult = $downloader.Download()
        $downloadResultName = Get-OperationResultName -Code ([int]$downloadResult.ResultCode)
        if ($downloadResult.ResultCode -notin 2, 3) {
            throw "Windows Update download failed with result '$downloadResultName'."
        }

        $installCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $downloadCollection.Count; $index++) {
            $update = $downloadCollection.Item($index)
            if ($update.IsDownloaded) {
                [void]$installCollection.Add($update)
                $result.downloadedCount++
            }
        }
        if ($installCollection.Count -eq 0) {
            throw 'No updates were downloaded successfully.'
        }

        Write-GuestLog -Level Information -Stage Install -Message 'Installing downloaded updates.' -Data @{
            count = $installCollection.Count
        }
        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $installCollection
        $installResult = $installer.Install()
        $result.rebootRequired = [bool]($installResult.RebootRequired -or $systemInformation.RebootRequired)

        for ($index = 0; $index -lt $installCollection.Count; $index++) {
            $update = $installCollection.Item($index)
            $perUpdateResult = $installResult.GetUpdateResult($index)
            $code = [int]$perUpdateResult.ResultCode
            $succeeded = $code -in 2, 3
            if ($succeeded) { $result.installedCount++ } else { $result.failedCount++ }
            $kbArticleIds = @($update.KBArticleIDs | ForEach-Object { "KB$_" })
            $hResultUnsigned = [BitConverter]::ToUInt32(
                [BitConverter]::GetBytes([int32]$perUpdateResult.HResult), 0
            )
            $result.updates += [ordered]@{
                title = $update.Title
                kbArticleIds = $kbArticleIds
                resultCode = $code
                result = Get-OperationResultName -Code $code
                hResult = ('0x{0:X8}' -f $hResultUnsigned)
                rebootRequired = [bool]$update.RebootRequired
            }
        }

        $overallResult = Get-OperationResultName -Code ([int]$installResult.ResultCode)
        if ($installResult.ResultCode -notin 2, 3 -or $result.failedCount -gt 0) {
            throw "Windows Update installation completed as '$overallResult' with $($result.failedCount) failed update(s)."
        }
        $result.status = 'Installed'
        Write-GuestLog -Level Information -Stage Install -Message 'Update installation cycle completed.' -Data @{
            installedCount = $result.installedCount
            rebootRequired = $result.rebootRequired
            result = $overallResult
        }
    }
}
catch {
    $result.status = 'Failed'
    $result.error = [ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        fullyQualifiedErrorId = $_.FullyQualifiedErrorId
        scriptStackTrace = $_.ScriptStackTrace
    }
    Write-GuestLog -Level Error -Stage Failure -Message $_.Exception.Message -Data @{
        type = $_.Exception.GetType().FullName
    }
}
finally {
    $completed = [DateTime]::UtcNow
    $result.completedUtc = $completed.ToString('o')
    $result.durationSeconds = [Math]::Round(($completed - $started).TotalSeconds, 2)
    $parent = Split-Path -Parent $ResultPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryResult = "$ResultPath.tmp"
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryResult -Encoding utf8
    Move-Item -LiteralPath $temporaryResult -Destination $ResultPath -Force
}

if ($result.status -eq 'Failed') { exit 1 }
exit 0
