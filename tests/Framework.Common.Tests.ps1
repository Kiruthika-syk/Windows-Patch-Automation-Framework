BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'scripts/Modules/Framework.Common.psm1') -Force
}

Describe 'Framework configuration' {
    BeforeEach {
        $settingsPath = Join-Path $TestDrive 'settings.json'
        '{"vCenterServer":"vc.example.com"}' | Set-Content -LiteralPath $settingsPath
    }

    It 'returns only enabled inventory rows' {
        $inventoryPath = Join-Path $TestDrive 'vms.csv'
        @'
VMName,Enabled,VCenterServer
vm-01,true,
vm-02,false,
'@ | Set-Content -LiteralPath $inventoryPath

        $result = Import-FrameworkConfiguration -SettingsPath $settingsPath -InventoryPath $inventoryPath
        $result.Inventory.Count | Should -Be 1
        $result.Inventory[0].VMName | Should -Be 'vm-01'
    }

    It 'rejects duplicate enabled VM names' {
        $inventoryPath = Join-Path $TestDrive 'duplicates.csv'
        @'
VMName,Enabled
vm-01,true
vm-01,yes
'@ | Set-Content -LiteralPath $inventoryPath

        { Import-FrameworkConfiguration -SettingsPath $settingsPath -InventoryPath $inventoryPath } |
            Should -Throw '*Duplicate enabled VM names*'
    }

    It 'rejects an inventory with no enabled VMs' {
        $inventoryPath = Join-Path $TestDrive 'disabled.csv'
        "VMName,Enabled`nvm-01,false" | Set-Content -LiteralPath $inventoryPath

        { Import-FrameworkConfiguration -SettingsPath $settingsPath -InventoryPath $inventoryPath } |
            Should -Throw '*no enabled rows*'
    }
}

Describe 'Framework settings validation' {
    BeforeAll {
        $validSettings = [pscustomobject]@{
            vCenterServer = 'vc.example.com'
            ignoreInvalidCertificate = $false
            guestWorkingDirectory = 'C:\ProgramData\Patch'
            windowsUpdateSearchCriteria = 'IsInstalled=0'
            autoRebootWhenRequired = $true
            maxPatchCycles = 8
            maxRebootOnlyCycles = 2
            postRebootWarmUpSeconds = 90
            throttleLimit = 4
            pollIntervalSeconds = 15
            timeouts = [pscustomobject]@{
                webOperationSeconds = 300
                toolsReadySeconds = 900
                patchCycleSeconds = 7200
                repairCycleSeconds = 7200
                rebootSeconds = 1800
            }
            retry = [pscustomobject]@{ maxAttempts = 3; initialDelaySeconds = 10 }
        }
    }

    It 'accepts bounded production settings' {
        { Assert-FrameworkSettings -Settings $validSettings } | Should -Not -Throw
    }

    It 'rejects an unsafe throttle' {
        $invalid = $validSettings.PSObject.Copy()
        $invalid.throttleLimit = 0
        { Assert-FrameworkSettings -Settings $invalid } | Should -Throw '*throttleLimit*'
    }
}

Describe 'Retry behavior' {
    It 'returns after a transient failure' {
        $script:attempts = 0
        $value = Invoke-WithRetry -Operation {
            $script:attempts++
            if ($script:attempts -lt 2) { throw 'transient' }
            'success'
        } -OperationName test -MaxAttempts 2 -InitialDelaySeconds 1

        $value | Should -Be 'success'
        $script:attempts | Should -Be 2
    }

    It 'throws a bounded final error' {
        { Invoke-WithRetry -Operation { throw 'persistent' } -OperationName test `
                -MaxAttempts 1 -InitialDelaySeconds 1 } |
            Should -Throw "*failed after 1 attempts*persistent*"
    }
}

Describe 'Compliance reporting' {
    It 'generates JSON CSV and HTML reports' {
        $result = [pscustomobject]@{
            VMName = 'vm-01'; Status = 'Compliant'; Cycles = 2; UpdatesFound = 3
            UpdatesInstalled = 3; Reboots = 1; StartUtc = '2026-01-01T00:00:00Z'
            EndUtc = '2026-01-01T00:10:00Z'; DurationSeconds = 600
            ErrorStage = $null; ErrorMessage = $null; Updates = @()
        }
        $paths = Export-ComplianceReports -Results @($result) -OutputDirectory (Join-Path $TestDrive 'reports')

        $paths.Json | Should -Exist
        $paths.Csv | Should -Exist
        $paths.Html | Should -Exist
        (Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json).Status | Should -Be 'Compliant'
    }
}
