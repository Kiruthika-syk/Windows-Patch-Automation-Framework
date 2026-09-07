Describe 'PowerShell source' {
    $FrameworkRoot = Split-Path -Parent $PSScriptRoot
    $SourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $FrameworkRoot 'scripts') -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1')

    It '<Name> parses without syntax errors' -ForEach $SourceFiles {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'uses only VMware Guest Operations for guest interaction' {
        $root = Split-Path -Parent $PSScriptRoot
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File |
            Where-Object Extension -in '.ps1', '.psm1')
        $scriptContent = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $scriptContent | Should -Match 'Invoke-VMScript'
        $scriptContent | Should -Match 'Copy-VMGuestFile'
        $scriptContent | Should -Not -Match '\bEnter-PSSession\b|\bNew-PSSession\b|\bInvoke-Command\b'
        $scriptContent | Should -Not -Match '\bwinrs\b|\bmstsc\b'
    }

    It 'uses native Windows Update COM interfaces' {
        $root = Split-Path -Parent $PSScriptRoot
        $guestScript = Get-Content -LiteralPath (Join-Path $root 'scripts/Guest/Invoke-WindowsUpdate.ps1') -Raw
        $guestScript | Should -Match 'Microsoft\.Update\.Session'
        $guestScript | Should -Match 'AcceptEula'
        $guestScript | Should -Match 'CreateUpdateDownloader'
        $guestScript | Should -Match 'CreateUpdateInstaller'
    }
}

Describe 'Configuration and workflow' {
    It 'contains valid JSON settings with bounded safety controls' {
        $root = Split-Path -Parent $PSScriptRoot
        $settings = Get-Content -LiteralPath (Join-Path $root 'config/settings.json') -Raw | ConvertFrom-Json
        $settings.maxPatchCycles | Should -BeGreaterThan 0
        $settings.throttleLimit | Should -BeGreaterThan 0
        $settings.autoRebootWhenRequired | Should -BeTrue
        $settings.timeouts.patchCycleSeconds | Should -BeGreaterThan 0
        $settings.ignoreInvalidCertificate | Should -BeTrue
    }

    It 'injects credentials exclusively from GitHub secrets' {
        $root = Split-Path -Parent $PSScriptRoot
        $workflow = Get-Content -LiteralPath (Join-Path $root '.github/workflows/windows-patch.yml') -Raw
        foreach ($secret in 'VCENTER_USERNAME', 'VCENTER_PASSWORD', 'WINDOWS_GUEST_USERNAME', 'WINDOWS_GUEST_PASSWORD') {
            $workflow | Should -Match ([regex]::Escape('${{ secrets.' + $secret + ' }}'))
        }
        $workflow | Should -Match 'if:\s*always\(\)'
        $workflow | Should -Match 'actions/upload-artifact@v4'
    }
}
