Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Connect-PatchVCenter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][pscredential]$Credential,
        [bool]$IgnoreInvalidCertificate,
        [ValidateRange(30, 3600)][int]$WebOperationTimeoutSeconds = 300
    )

    $certificateAction = if ($IgnoreInvalidCertificate) { 'Ignore' } else { 'Fail' }
    Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP:$false -InvalidCertificateAction $certificateAction `
        -WebOperationTimeoutSeconds $WebOperationTimeoutSeconds -Confirm:$false | Out-Null
    Connect-VIServer -Server $Server -Credential $Credential -Force -ErrorAction Stop
}

function Get-UniquePatchVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)]$Server
    )

    $matches = @(Get-VM -Name $VMName -Server $Server -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0) { throw "VM '$VMName' was not found in vCenter." }
    if ($matches.Count -gt 1) { throw "VM name '$VMName' is ambiguous ($($matches.Count) matches)." }
    $matches[0]
}

function Test-VMToolsReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server
    )

    $freshVM = Get-VM -Id $VM.Id -Server $Server -ErrorAction Stop
    $toolsStatus = $freshVM.ExtensionData.Guest.ToolsRunningStatus
    $guestState = $freshVM.ExtensionData.Guest.GuestState
    ($freshVM.PowerState -eq 'PoweredOn' -and
        $toolsStatus -eq 'guestToolsRunning' -and
        $guestState -eq 'running')
}

function Wait-VMToolsReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server,
        [ValidateRange(30, 7200)][int]$TimeoutSeconds = 900,
        [ValidateRange(2, 120)][int]$PollSeconds = 10,
        [switch]$RequireObservedNotReady
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $observedNotReady = -not $RequireObservedNotReady
    do {
        try {
            $ready = Test-VMToolsReady -VM $VM -Server $Server
            if (-not $ready) { $observedNotReady = $true }
            if ($ready -and $observedNotReady) { return }
        }
        catch {
            $observedNotReady = $true
        }
        Start-Sleep -Seconds $PollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "VMware Tools/guest readiness timed out after $TimeoutSeconds seconds for '$($VM.Name)'."
}

function Invoke-GuestPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$ScriptText
    )

    $result = Invoke-VMScript -VM $VM -GuestCredential $GuestCredential -ScriptType PowerShell `
        -ScriptText $ScriptText -ErrorAction Stop
    if ($result.ExitCode -ne 0) {
        throw "Guest operation exited with code $($result.ExitCode): $($result.ScriptOutput)"
    }
    $result.ScriptOutput
}

function Initialize-GuestPatchWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory
    )

    $escaped = $GuestWorkingDirectory.Replace("'", "''")
    Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path '$escaped' -Force | Out-Null
"@ | Out-Null
}

function Copy-PatchScriptToGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $Source -Destination $Destination `
        -LocalToGuest -Force -ErrorAction Stop | Out-Null
}

function Start-GuestPatchCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$GuestScriptPath,
        [Parameter(Mandatory)][string]$GuestWorkingDirectory,
        [Parameter(Mandatory)][string]$SearchCriteria,
        [ValidateRange(1, 100)][int]$Cycle
    )

    $guestRoot = $GuestWorkingDirectory.TrimEnd('\', '/')
    $resultPath = "$guestRoot\cycle-$Cycle-result.json"
    $logPath = "$guestRoot\cycle-$Cycle-log.jsonl"
    $pidPath = "$guestRoot\cycle-$Cycle.pid"
    $escapedScript = $GuestScriptPath.Replace("'", "''")
    $escapedResult = $resultPath.Replace("'", "''")
    $escapedLog = $logPath.Replace("'", "''")
    $escapedPid = $pidPath.Replace("'", "''")
    $escapedCriteria = $SearchCriteria.Replace("'", "''")
    $patchCommand = "& '$escapedScript' -Cycle $Cycle -ResultPath '$escapedResult' -LogPath '$escapedLog' -SearchCriteria '$escapedCriteria'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($patchCommand))

    $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
`$ErrorActionPreference = 'Stop'
Remove-Item -LiteralPath '$escapedResult', '$escapedLog', '$escapedPid' -Force -ErrorAction SilentlyContinue
`$arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','$encodedCommand')
`$process = Start-Process -FilePath "`$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList `$arguments -WindowStyle Hidden -PassThru
Set-Content -LiteralPath '$escapedPid' -Value `$process.Id -Encoding ascii
Write-Output `$process.Id
"@

    [pscustomobject]@{
        ProcessId = [int]($output.Trim() -split '\s+')[-1]
        ResultPath = $resultPath
        LogPath = $logPath
        PidPath = $pidPath
    }
}

function Wait-GuestPatchCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)]$CycleHandle,
        [ValidateRange(60, 28800)][int]$TimeoutSeconds = 7200,
        [ValidateRange(5, 300)][int]$PollSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $escapedResult = $CycleHandle.ResultPath.Replace("'", "''")
    $pid = $CycleHandle.ProcessId
    $lastPollError = $null
    do {
        try {
            $output = Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText @"
if (Test-Path -LiteralPath '$escapedResult' -PathType Leaf) { 'COMPLETE' }
elseif (Get-Process -Id $pid -ErrorAction SilentlyContinue) { 'RUNNING' }
else { 'EXITED' }
"@
            if ($output -match 'COMPLETE') { return }
            if ($output -match 'EXITED') {
                throw "Guest patch process $pid exited without producing a result file."
            }
            $lastPollError = $null
        }
        catch {
            if ($_.Exception.Message -match 'exited without producing') { throw }
            $lastPollError = $_.Exception.Message
        }
        Start-Sleep -Seconds $PollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)

    try {
        Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText `
            "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" | Out-Null
    }
    catch { }
    $detail = if ($lastPollError) { " Last polling error: $lastPollError" } else { '' }
    throw "Windows Update cycle exceeded the $TimeoutSeconds second timeout.$detail"
}

function Copy-GuestPatchArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)]$CycleHandle,
        [Parameter(Mandatory)][string]$LocalDirectory,
        [ValidateRange(1, 100)][int]$Cycle
    )

    New-Item -ItemType Directory -Path $LocalDirectory -Force | Out-Null
    $localResult = Join-Path $LocalDirectory "cycle-$Cycle-result.json"
    $localLog = Join-Path $LocalDirectory "cycle-$Cycle-guest.jsonl"
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $CycleHandle.ResultPath `
        -Destination $localResult -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Copy-VMGuestFile -VM $VM -GuestCredential $GuestCredential -Source $CycleHandle.LogPath `
        -Destination $localLog -GuestToLocal -Force -ErrorAction Stop | Out-Null
    Get-Content -LiteralPath $localResult -Raw | ConvertFrom-Json -Depth 20
}

function Restart-PatchVMGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [ValidateRange(30, 7200)][int]$TimeoutSeconds = 1200,
        [ValidateRange(2, 120)][int]$PollSeconds = 10
    )

    try {
        Invoke-GuestPowerShell -VM $VM -GuestCredential $GuestCredential -ScriptText `
            'Restart-Computer -Force' | Out-Null
    }
    catch {
        # Guest Operations commonly loses the response while Windows is shutting down.
    }
    Wait-VMToolsReady -VM $VM -Server $Server -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -RequireObservedNotReady
}

Export-ModuleMember -Function Connect-PatchVCenter, Get-UniquePatchVM, Test-VMToolsReady,
    Wait-VMToolsReady, Invoke-GuestPowerShell, Initialize-GuestPatchWorkspace,
    Copy-PatchScriptToGuest, Start-GuestPatchCycle, Wait-GuestPatchCycle,
    Copy-GuestPatchArtifacts, Restart-PatchVMGuest
