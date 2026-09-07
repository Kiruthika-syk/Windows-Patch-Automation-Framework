#requires -Version 7.2
<#
.SYNOPSIS
Validates patch configuration and tests vCenter connectivity for all configured sites.

.NOTES
Uses TWO separate credential sets from the environment:
- VCENTER_USERNAME / VCENTER_PASSWORD  -> vCenter SSO (e.g. user@strykercorp.com)
- WINDOWS_GUEST_USERNAME / WINDOWS_GUEST_PASSWORD -> Windows local admin inside each VM (e.g. Administrator)
Do not enter Windows RDP credentials when PowerCLI asks for vCenter login.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $PSScriptRoot '../config/settings.json'),
    [string]$InventoryPath = (Join-Path $PSScriptRoot '../config/vms.csv'),
    [string]$VCentersPath = (Join-Path $PSScriptRoot '../config/vcenters.json'),
    [switch]$ResolveAllInventory,
    [switch]$ExecutePatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModule = Join-Path $PSScriptRoot 'Modules/Framework.Common.psm1'
$guestOpsModule = Join-Path $PSScriptRoot 'Modules/VCenter.GuestOps.psm1'
Import-Module $commonModule -Force
Import-Module $guestOpsModule -Force

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw 'VMware.PowerCLI is required. Install-Module VMware.PowerCLI -RequiredVersion 13.3.0.24145081 -Scope CurrentUser -Force'
}

$configuration = Import-FrameworkConfiguration -SettingsPath $SettingsPath -InventoryPath $InventoryPath
$settings = $configuration.Settings
Assert-FrameworkSettings -Settings $settings

$vCenterUser = Get-RequiredEnvironmentVariable -Name 'VCENTER_USERNAME'
$vCenterPassword = Get-RequiredEnvironmentVariable -Name 'VCENTER_PASSWORD'
$guestUser = Get-RequiredEnvironmentVariable -Name 'WINDOWS_GUEST_USERNAME'
$guestPassword = Get-RequiredEnvironmentVariable -Name 'WINDOWS_GUEST_PASSWORD'

$vCenterCredential = [pscredential]::new($vCenterUser, (ConvertTo-SecureString $vCenterPassword -AsPlainText -Force))
$guestCredential = [pscredential]::new($guestUser, (ConvertTo-SecureString $guestPassword -AsPlainText -Force))
$vCenterPassword = $null
$guestPassword = $null
[GC]::Collect()

$siteConfig = Get-Content -LiteralPath $VCentersPath -Raw | ConvertFrom-Json -Depth 10
$inventoryRows = @(Import-Csv -LiteralPath $InventoryPath)
$rowsToCheck = if ($ResolveAllInventory) {
    @($inventoryRows)
}
else {
    @($inventoryRows | Where-Object { $_.Enabled -match '^(?i:true|yes|1)$' })
}

function Get-InventoryVCenter {
    param($Row)
    if (-not [string]::IsNullOrWhiteSpace($Row.VCenterServer)) {
        return $Row.VCenterServer.Trim()
    }
    return [string]$settings.vCenterServer
}

$serversToConnect = if ($ResolveAllInventory) {
    @($siteConfig.sites | ForEach-Object { $_.server } | Sort-Object -Unique)
}
else {
    @($rowsToCheck | ForEach-Object { Get-InventoryVCenter -Row $_ } | Sort-Object -Unique)
}

Write-Host '=== Windows Patch Environment Validation ===' -ForegroundColor Cyan
Write-Host "vCenter account: $vCenterUser"
Write-Host "Windows guest account: $guestUser"
Write-Host "vCenters to connect: $($serversToConnect -join ', ')"
Write-Host "Inventory rows to validate: $($rowsToCheck.Count)"
Write-Host ''
Write-Host 'NOTE: vCenter and Windows guest credentials are different.' -ForegroundColor Yellow
Write-Host '      RDP Administrator password is NOT the same as vCenter SSO unless you configured it that way.' -ForegroundColor Yellow

$connectionResults = @()
foreach ($server in $serversToConnect) {
    Write-Host "`nConnecting to vCenter $server..." -ForegroundColor Yellow
    try {
        $vi = Connect-PatchVCenter -Server $server -Credential $vCenterCredential `
            -IgnoreInvalidCertificate ([bool]$settings.ignoreInvalidCertificate) `
            -WebOperationTimeoutSeconds ([int]$settings.timeouts.webOperationSeconds)
        $vmCount = (Get-VM -Server $vi | Measure-Object).Count
        Write-Host "  vCenter connected. Visible VMs: $vmCount" -ForegroundColor Green
        $connectionResults += [pscustomobject]@{
            VCenter = $server
            Status = 'Connected'
            VMCount = $vmCount
            Error = ''
        }
    }
    catch {
        Write-Host "  vCenter FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $connectionResults += [pscustomobject]@{
            VCenter = $server
            Status = 'Failed'
            VMCount = 0
            Error = $_.Exception.Message
        }
    }
}

$vmResults = @()
foreach ($row in $rowsToCheck) {
    $vmName = $row.VMName.Trim()
    $server = Get-InventoryVCenter -Row $row

    Write-Host "`nChecking VM '$vmName' on $server..." -ForegroundColor Yellow
    try {
        $vi = Get-PatchVCenterSession -Server $server
        $vm = Get-UniquePatchVM -VMName $vmName -Server $vi
        $tools = $vm.ExtensionData.Guest.ToolsRunningStatus
        $guestState = $vm.ExtensionData.Guest.GuestState
        $guestIp = ($vm.ExtensionData.Guest.IpAddress -join ', ')
        $ready = Test-VMToolsReady -VM $vm -Server $vi

        Write-Host '  Testing Windows guest credentials via Guest Operations...' -ForegroundColor Yellow
        $guestHost = Test-GuestCredential -VM $vm -GuestCredential $guestCredential
        Write-Host "  VM found. PowerState=$($vm.PowerState) Tools=$tools GuestState=$guestState IP=$guestIp GuestHost=$guestHost Ready=$ready" -ForegroundColor Green
        $vmResults += [pscustomobject]@{
            VMName = $vmName
            VCenter = $server
            Status = 'Found'
            PowerState = [string]$vm.PowerState
            ToolsStatus = [string]$tools
            GuestState = [string]$guestState
            GuestIP = $guestIp
            GuestHost = $guestHost
            ToolsReady = $ready
            Enabled = $row.Enabled
            Error = ''
        }
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $vmResults += [pscustomobject]@{
            VMName = $vmName
            VCenter = $server
            Status = 'Failed'
            PowerState = ''
            ToolsStatus = ''
            GuestState = ''
            GuestIP = ''
            GuestHost = ''
            ToolsReady = $false
            Enabled = $row.Enabled
            Error = $_.Exception.Message
        }
    }
}

$reportDir = Join-Path $PSScriptRoot '../output/validation'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$connectionResults | Export-Csv -LiteralPath (Join-Path $reportDir "vcenters_$stamp.csv") -NoTypeInformation
if ($vmResults.Count -gt 0) {
    $vmResults | Export-Csv -LiteralPath (Join-Path $reportDir "vms_$stamp.csv") -NoTypeInformation
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$connectionResults | Format-Table -AutoSize
if ($vmResults.Count -gt 0) {
    $vmResults | Format-Table VMName, VCenter, Status, PowerState, ToolsStatus, GuestHost, ToolsReady, Enabled -AutoSize
}

$failedConnections = @($connectionResults | Where-Object Status -ne 'Connected').Count
$failedVMs = @($vmResults | Where-Object Status -ne 'Found').Count
if ($failedConnections -gt 0 -or $failedVMs -gt 0) {
    throw "Validation failed. vCenter failures: $failedConnections, VM failures: $failedVMs"
}

if ($rowsToCheck.Count -eq 0) {
    Write-Warning 'No enabled VMs in inventory. Set Enabled=true on approved VMs before ExecutePatch.'
}

if ($ExecutePatch) {
    if ($rowsToCheck.Count -eq 0) {
        throw 'Cannot execute patch run with zero enabled VMs.'
    }
    Write-Host "`n=== Starting patch run ===" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Invoke-WindowsPatchAutomation.ps1') `
        -SettingsPath $SettingsPath `
        -InventoryPath $InventoryPath `
        -FailOnNonCompliance
}

Write-Host "`nValidation completed successfully." -ForegroundColor Green
