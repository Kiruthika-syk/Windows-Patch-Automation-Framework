Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PlainText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Write-StructuredLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Debug', 'Information', 'Warning', 'Error')][string]$Level,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Message,
        [string]$VMName,
        [hashtable]$Data = @{}
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level        = $Level
        stage        = $Stage
        vmName       = $VMName
        message      = $Message
        data         = $Data
    }
    ($entry | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$OperationName,
        [ValidateRange(1, 20)][int]$MaxAttempts = 3,
        [ValidateRange(1, 600)][int]$InitialDelaySeconds = 5,
        [scriptblock]$OnRetry
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Operation
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                throw "Operation '$OperationName' failed after $MaxAttempts attempts. $($_.Exception.Message)"
            }
            if ($OnRetry) {
                & $OnRetry $attempt $_
            }
            $delay = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), 300)
            Start-Sleep -Seconds ([int]$delay)
        }
    }
}

function Get-RequiredEnvironmentVariable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable '$Name' is not set."
    }
    $value
}

function Import-FrameworkConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][string]$InventoryPath
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Settings file not found: $SettingsPath"
    }
    if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
        throw "Inventory file not found: $InventoryPath"
    }

    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json -Depth 20
    $inventory = @(Import-Csv -LiteralPath $InventoryPath)
    if ($inventory.Count -eq 0) {
        throw 'The VM inventory is empty.'
    }

    $requiredColumns = 'VMName', 'Enabled'
    foreach ($column in $requiredColumns) {
        if (-not ($inventory[0].PSObject.Properties.Name -contains $column)) {
            throw "Inventory is missing required column '$column'."
        }
    }

    $enabledVMs = @($inventory | Where-Object { $_.Enabled -match '^(?i:true|yes|1)$' })
    if ($enabledVMs.Count -eq 0) {
        throw 'The VM inventory contains no enabled rows.'
    }
    $duplicates = @($enabledVMs | Group-Object VMName | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        throw "Duplicate enabled VM names: $($duplicates.Name -join ', ')"
    }
    if ($enabledVMs.Where({ [string]::IsNullOrWhiteSpace($_.VMName) }).Count -gt 0) {
        throw 'Every enabled inventory row must contain VMName.'
    }

    [pscustomobject]@{ Settings = $settings; Inventory = $enabledVMs }
}

function Assert-FrameworkSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)

    $required = 'vCenterServer', 'ignoreInvalidCertificate', 'guestWorkingDirectory',
        'windowsUpdateSearchCriteria', 'autoRebootWhenRequired', 'maxPatchCycles', 'throttleLimit',
        'pollIntervalSeconds', 'timeouts', 'retry'
    foreach ($name in $required) {
        if ($Settings.PSObject.Properties.Name -notcontains $name) {
            throw "Missing required setting '$name'."
        }
    }
    foreach ($name in 'vCenterServer', 'guestWorkingDirectory', 'windowsUpdateSearchCriteria') {
        if ([string]::IsNullOrWhiteSpace([string]$Settings.$name)) {
            throw "Setting '$name' cannot be empty."
        }
    }
    if ([string]$Settings.guestWorkingDirectory -notmatch '^[A-Za-z]:\\') {
        throw 'guestWorkingDirectory must be an absolute Windows drive path.'
    }
    if ([int]$Settings.maxPatchCycles -lt 1 -or [int]$Settings.maxPatchCycles -gt 100) {
        throw 'maxPatchCycles must be between 1 and 100.'
    }
    if ([int]$Settings.throttleLimit -lt 1 -or [int]$Settings.throttleLimit -gt 100) {
        throw 'throttleLimit must be between 1 and 100.'
    }
    if ([int]$Settings.pollIntervalSeconds -lt 5 -or [int]$Settings.pollIntervalSeconds -gt 300) {
        throw 'pollIntervalSeconds must be between 5 and 300.'
    }

    foreach ($name in 'webOperationSeconds', 'toolsReadySeconds', 'patchCycleSeconds', 'repairCycleSeconds', 'rebootSeconds') {
        if ($Settings.timeouts.PSObject.Properties.Name -notcontains $name -or [int]$Settings.timeouts.$name -le 0) {
            throw "Timeout '$name' must be present and greater than zero."
        }
    }
    foreach ($name in 'maxAttempts', 'initialDelaySeconds') {
        if ($Settings.retry.PSObject.Properties.Name -notcontains $name -or [int]$Settings.retry.$name -le 0) {
            throw "Retry setting '$name' must be present and greater than zero."
        }
    }
}

function Export-ComplianceReports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $orderedResults = @($Results | Sort-Object VMName)
    $jsonPath = Join-Path $OutputDirectory 'compliance-report.json'
    $csvPath = Join-Path $OutputDirectory 'compliance-report.csv'
    $htmlPath = Join-Path $OutputDirectory 'compliance-report.html'

    $orderedResults | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    $orderedResults | Select-Object VMName, Status, Cycles, UpdatesFound, UpdatesInstalled, Reboots, StartUtc, EndUtc, DurationSeconds, ErrorStage, ErrorMessage |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

    $style = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #24292f; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #d0d7de; padding: 8px; text-align: left; }
th { background: #f6f8fa; } tr:nth-child(even) { background: #fafbfc; }
h1 { margin-bottom: 4px; } .meta { color: #57606a; margin-bottom: 20px; }
</style>
'@
    $preContent = "<h1>Windows Patch Compliance Report</h1><div class='meta'>Generated UTC: $([DateTime]::UtcNow.ToString('u'))</div>"
    $orderedResults | Select-Object VMName, Status, Cycles, UpdatesFound, UpdatesInstalled, Reboots, DurationSeconds, ErrorStage, ErrorMessage |
        ConvertTo-Html -Head $style -PreContent $preContent |
        Set-Content -LiteralPath $htmlPath -Encoding utf8

    [pscustomobject]@{ Json = $jsonPath; Csv = $csvPath; Html = $htmlPath }
}

Export-ModuleMember -Function ConvertTo-PlainText, Write-StructuredLog, Invoke-WithRetry,
    Get-RequiredEnvironmentVariable, Import-FrameworkConfiguration, Assert-FrameworkSettings,
    Export-ComplianceReports
