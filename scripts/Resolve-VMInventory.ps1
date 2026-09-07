#requires -Version 7.2
<#
.SYNOPSIS
Resolves vCenter VM names from IP addresses across BLR, FW, and STC vCenters.
#>
[CmdletBinding()]
param(
    [string[]]$TargetIPs = @(
        '10.90.122.105',
        '10.90.122.106',
        '10.90.105.180',
        '10.90.128.187',
        '10.90.128.188'
    ),
    [string]$VCentersPath = (Join-Path $PSScriptRoot '../config/vcenters.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '../output/validation/vm-resolution.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw 'Install VMware.PowerCLI first.'
}

$guestOpsModule = Join-Path $PSScriptRoot 'Modules/VCenter.GuestOps.psm1'
Import-Module $guestOpsModule -Force

$vCenterUser = $env:VCENTER_USERNAME
$vCenterPassword = $env:VCENTER_PASSWORD
if ([string]::IsNullOrWhiteSpace($vCenterUser) -or [string]::IsNullOrWhiteSpace($vCenterPassword)) {
    throw 'Set VCENTER_USERNAME and VCENTER_PASSWORD environment variables.'
}

$credential = [pscredential]::new($vCenterUser, (ConvertTo-SecureString $vCenterPassword -AsPlainText -Force))
$siteConfig = Get-Content -LiteralPath $VCentersPath -Raw | ConvertFrom-Json -Depth 10
$matches = @()

foreach ($site in @($siteConfig.sites)) {
    $server = [string]$site.server
    Write-Host "Scanning $server ($($site.id))..." -ForegroundColor Cyan
    try {
        $vi = Connect-PatchVCenter -Server $server -Credential $credential -IgnoreInvalidCertificate $true
        $vms = @(Get-VM -Server $vi)
        foreach ($vm in $vms) {
            $ips = @($vm.ExtensionData.Guest.IpAddress | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            foreach ($ip in $ips) {
                if ($TargetIPs -contains $ip) {
                    $matches += [pscustomobject]@{
                        IPAddress = $ip
                        VMName = $vm.Name
                        VCenterServer = $server
                        Site = $site.id
                        PowerState = [string]$vm.PowerState
                        GuestOS = [string]$vm.Guest.OSFullName
                        ToolsStatus = [string]$vm.ExtensionData.Guest.ToolsRunningStatus
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to scan ${server}: $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
$matches | Sort-Object IPAddress | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
Write-Host "Resolved $($matches.Count) VM(s). Output: $OutputPath" -ForegroundColor Green
$matches | Format-Table -AutoSize
