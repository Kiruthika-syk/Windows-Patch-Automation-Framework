# Windows Patch Automation Framework
## Operations Manual

**Repository:** https://github.com/Kiruthika-syk/Windows-Patch-Automation-Framework  
**Version:** 1.0  
**Date:** September 2026

---

## 1. Executive Summary

This framework automates Windows security and quality updates on VMware virtual machines. It scans for missing updates, installs them automatically, reboots the VM when a restart is required, and repeats until the server is fully patched or a safety limit is reached.

The solution is designed for enterprise use. It does not use WinRM, RDP, or direct network login to Windows servers. All guest interaction happens through VMware vCenter Guest Operations (PowerCLI).

---

## 2. Will This Code Work?

### 2.1 What is already validated

| Item | Status |
|------|--------|
| PowerShell syntax | Passed (all scripts parse cleanly) |
| Unit and static tests | 16/16 Pester tests pass |
| Auto-update logic | Implemented in guest script |
| Auto-reboot logic | Implemented in orchestrator |
| GitHub workflow structure | Valid YAML, correct paths |
| Code pushed to GitHub | Available on Kiruthika-syk account |

### 2.2 What you must configure before it works in production

The code is **technically correct** but will **not run successfully** until the following are in place:

1. **Self-hosted GitHub Actions runner**
   - Must be Windows
   - Must have labels: `self-hosted`, `windows`, `vcenter`
   - Must reach vCenter on HTTPS (port 443)
   - Must have PowerShell 7.2 or later

2. **vCenter access**
   - Update `config/settings.json` with your real vCenter FQDN
   - Create a vCenter service account with Guest Operations permissions
   - Store credentials in GitHub secrets: `VCENTER_USERNAME`, `VCENTER_PASSWORD`

3. **Windows guest requirements**
   - VMware Tools installed and running on every target VM
   - VM must be powered on
   - Guest admin account with local administrator rights
   - Store credentials in GitHub secrets: `WINDOWS_GUEST_USERNAME`, `WINDOWS_GUEST_PASSWORD`
   - Windows Update must reach WSUS or Microsoft Update

4. **Inventory configuration**
   - Edit `config/vms.csv` with exact vCenter VM names
   - Set `Enabled=true` only for approved servers

5. **GitHub environment**
   - Create environment named `windows-patching`
   - Add the four secrets above to that environment

### 2.3 Honest assessment

| Scenario | Will it work? |
|----------|---------------|
| Run as-is without configuration | **No** |
| After full setup with test VM | **Yes** |
| Scheduled weekly patching of fleet | **Yes**, once runner and secrets are ready |
| Patching without VMware/vCenter | **No** — this framework requires VMware |

**Recommendation:** Test on one non-production VM with a snapshot before enabling the weekly schedule.

---

## 3. What It Does

### 3.1 High-level purpose

- Finds Windows updates that are not yet installed
- Downloads and installs them automatically
- Accepts update EULAs without manual intervention
- Reboots the VM when Windows Update requires a restart
- Keeps scanning and patching until no updates remain
- Produces compliance reports (CSV, HTML, JSON)
- Uploads logs and reports as GitHub Actions artifacts

### 3.2 What it does NOT do

- Does not patch physical servers (only VMware VMs)
- Does not use Ansible, WinRM, or SSH
- Does not create VM snapshots automatically
- Does not patch Linux systems
- Does not store passwords in config files

---

## 4. How It Works (Architecture)

### 4.1 Components

```
GitHub Actions Workflow
        |
        v
Invoke-WindowsPatchAutomation.ps1  (Orchestrator on runner)
        |
        +-- Connect to vCenter (PowerCLI)
        +-- For each VM in vms.csv (parallel, throttled)
                |
                v
        VCenter.GuestOps.psm1
                |
                +-- Copy Invoke-WindowsUpdate.ps1 into guest
                +-- Start update script inside guest
                +-- Poll for completion
                +-- Reboot guest if required
                +-- Repeat until compliant
                |
                v
        Invoke-WindowsUpdate.ps1  (Runs inside Windows VM)
                |
                +-- Scan (Microsoft.Update.Session COM)
                +-- Accept EULAs
                +-- Download updates
                +-- Install updates
                +-- Write result JSON + logs
```

### 4.2 Step-by-step execution flow

**Phase A — Validation (GitHub hosted runner, Ubuntu)**
1. Checkout repository
2. Install Pester test module
3. Run 16 automated tests
4. If tests fail, patching job does not start

**Phase B — Patching (Self-hosted Windows runner)**
1. Checkout repository
2. Install VMware PowerCLI 13.3
3. Read `config/settings.json` and `config/vms.csv`
4. Load credentials from GitHub secrets (never from disk)
5. For each enabled VM:
   - Connect to vCenter
   - Verify VM is powered on and VMware Tools is running
   - Create guest working folder: `C:\ProgramData\EnterprisePatchAutomation`
   - Copy patch script to guest
   - Run update cycle inside guest
   - Wait for cycle to finish (up to 2 hours per cycle)
   - If reboot required and `autoRebootWhenRequired=true`, restart VM
   - Wait for VMware Tools to return after reboot
   - Repeat until no updates found or `maxPatchCycles` reached
6. Generate compliance reports in `output/<run-id>/`
7. Upload output folder as workflow artifact

**Phase C — Guest update cycle (inside Windows VM)**
1. Create Windows Update session (COM API)
2. Search for updates matching: `IsInstalled=0 and IsHidden=0`
3. If no updates and no pending reboot → status `NoUpdates` (compliant)
4. If no updates but reboot pending → status `RebootRequired`
5. Accept EULAs for applicable updates
6. Download updates
7. Install updates
8. Record KB numbers, result codes, reboot flag
9. Write `cycle-N-result.json` and `cycle-N-log.jsonl`

### 4.3 Convergence loop example

```
Cycle 1: Found 5 updates → Installed → Reboot required → Reboot VM
Cycle 2: Found 2 updates → Installed → Reboot required → Reboot VM
Cycle 3: Found 0 updates → Status: Compliant → Done
```

Maximum cycles default: 5 (configurable in settings.json)

---

## 5. Configuration Reference

### 5.1 config/settings.json

| Setting | Default | Description |
|---------|---------|-------------|
| vCenterServer | vcenter.example.com | vCenter FQDN — **must change** |
| ignoreInvalidCertificate | false | Keep false in production |
| guestWorkingDirectory | C:\ProgramData\EnterprisePatchAutomation | Staging folder inside guest |
| windowsUpdateSearchCriteria | IsInstalled=0 and IsHidden=0 | WUA search filter |
| autoRebootWhenRequired | true | Auto-reboot after updates needing restart |
| maxPatchCycles | 5 | Safety cap on scan/install loops |
| throttleLimit | 4 | Max VMs patched in parallel |
| pollIntervalSeconds | 15 | Guest operation polling interval |
| timeouts.patchCycleSeconds | 7200 | Max seconds per update cycle (2 hours) |
| timeouts.rebootSeconds | 1800 | Max seconds to wait for VM after reboot |
| retry.maxAttempts | 3 | Retries for transient vCenter errors |

### 5.2 config/vms.csv

| Column | Required | Example | Description |
|--------|----------|---------|-------------|
| VMName | Yes | WIN-APP-01 | Exact name in vCenter inventory |
| Enabled | Yes | true | Must be true/yes/1 to patch |
| VCenterServer | No | vc01.corp.local | Override default vCenter |
| Environment | No | Production | Metadata only |
| Owner | No | Infrastructure | Metadata only |
| MaintenanceWindow | No | Sunday-0200-UTC | Metadata only |

**Example:**
```
VMName,Enabled,VCenterServer,Environment,Owner,MaintenanceWindow
WIN-APP-01,true,vcenter.corp.local,Production,Infra,Sunday-0200-UTC
WIN-APP-02,false,,Production,Infra,Sunday-0200-UTC
```

---

## 6. How to Execute

### 6.1 One-time setup checklist

- [ ] Clone repo: `git clone https://github.com/Kiruthika-syk/Windows-Patch-Automation-Framework.git`
- [ ] Edit `config/settings.json` — set vCenterServer
- [ ] Edit `config/vms.csv` — add VMs, set Enabled=true for test VM
- [ ] Register self-hosted Windows runner with labels: self-hosted, windows, vcenter
- [ ] Create GitHub environment: `windows-patching`
- [ ] Add secrets to environment:
  - VCENTER_USERNAME
  - VCENTER_PASSWORD
  - WINDOWS_GUEST_USERNAME
  - WINDOWS_GUEST_PASSWORD
- [ ] Ensure test VM has VMware Tools running
- [ ] Ensure test VM can reach WSUS or Microsoft Update
- [ ] Take VM snapshot before first test run

### 6.2 Method 1 — Run via GitHub Actions (recommended)

1. Open: https://github.com/Kiruthika-syk/Windows-Patch-Automation-Framework
2. Go to **Actions** tab
3. Select **Windows Patch Automation** workflow
4. Click **Run workflow**
5. Select branch `main`
6. Click **Run workflow**
7. Monitor job progress:
   - Job 1: Validate framework (runs on GitHub Ubuntu runner)
   - Job 2: Patch Windows fleet (runs on your self-hosted runner)
8. When complete, download artifact: `windows-patch-results-<run-id>`
9. Review:
   - `compliance-report.html` — human-readable summary
   - `compliance-report.csv` — export for tracking
   - `master.jsonl` — full structured log

### 6.3 Method 2 — Run manually on self-hosted runner

On the Windows runner machine:

```powershell
# 1. Clone repository
git clone https://github.com/Kiruthika-syk/Windows-Patch-Automation-Framework.git
cd Windows-Patch-Automation-Framework

# 2. Install PowerCLI
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module VMware.PowerCLI -RequiredVersion 13.3.0.24145081 -Scope CurrentUser -Force

# 3. Set credentials (session only — do not save to disk)
$env:VCENTER_USERNAME = 'svc-vcenter@corp.local'
$env:VCENTER_PASSWORD = '<password>'
$env:WINDOWS_GUEST_USERNAME = 'CORP\svc-patch'
$env:WINDOWS_GUEST_PASSWORD = '<password>'

# 4. Run orchestrator
./scripts/Invoke-WindowsPatchAutomation.ps1 `
  -SettingsPath ./config/settings.json `
  -InventoryPath ./config/vms.csv `
  -OutputDirectory ./output `
  -FailOnNonCompliance

# 5. Open reports
Start-Process ./output/<run-id>/compliance-report.html
```

### 6.4 Method 3 — Run tests only (no vCenter needed)

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force
Invoke-Pester ./tests -Output Detailed
```

Expected result: **16 tests passed, 0 failed**

### 6.5 Scheduled execution

The workflow runs automatically every **Sunday at 02:00 UTC** (cron: `0 2 * * 0`).

To change schedule, edit `.github/workflows/windows-patch.yml` and align with your maintenance window in `vms.csv`.

---

## 7. Output and Reports

Each run creates a folder: `output/<run-id>/`

| File | Purpose |
|------|---------|
| master.jsonl | Complete run log (all VMs) |
| compliance-report.html | Visual compliance report |
| compliance-report.csv | Spreadsheet export |
| compliance-report.json | Machine-readable full results |
| vm-logs/<vm>/orchestrator.jsonl | Per-VM orchestration log |
| vm-logs/<vm>/cycle-1-result.json | Guest update cycle result |
| vm-logs/<vm>/cycle-1-guest.jsonl | Guest update detailed log |

### VM status values

| Status | Meaning |
|--------|---------|
| Compliant | No applicable updates remain |
| Failed | Error during patching |
| MaxCyclesExceeded | Updates still found after safety cap |

---

## 8. Troubleshooting Quick Reference

| Problem | Likely cause | Fix |
|---------|--------------|-----|
| Workflow stuck on "Patch Windows fleet" | No self-hosted runner | Register runner with correct labels |
| VM not found | Wrong VMName in CSV | Match exact vCenter inventory name |
| Tools readiness timeout | VMware Tools not running | Repair/start Tools on VM |
| Guest auth failed | Wrong guest credentials | Verify admin account in secrets |
| Certificate error | vCenter cert not trusted | Install CA on runner; keep ignoreInvalidCertificate=false |
| Patch cycle timeout | Large update set or slow WSUS | Increase patchCycleSeconds; check WSUS health |
| MaxCyclesExceeded | Many pending updates | Review cycle logs; increase maxPatchCycles after review |

Full details: see TROUBLESHOOTING.md in the repository.

---

## 9. Security Notes

- Never commit passwords to git
- Use dedicated service accounts (not personal accounts)
- Restrict vCenter permissions to Guest Operations only
- Use GitHub environment protection rules for production
- Do not run untrusted PR code on the privileged runner
- Treat compliance reports as internal security data

Full details: see SECURITY.md in the repository.

---

## 10. Prerequisites Summary

| Component | Requirement |
|-----------|-------------|
| Hypervisor | VMware vCenter + ESXi |
| Target OS | Windows Server / Windows Client (VM) |
| VMware Tools | Installed and running |
| Runner OS | Windows with PowerShell 7.2+ |
| Network | Runner → vCenter (443); Guest → WSUS/Windows Update |
| GitHub | Repository + self-hosted runner + secrets |
| Accounts | vCenter service account + guest local admin |

---

## 11. Support and Repository Links

- **Repository:** https://github.com/Kiruthika-syk/Windows-Patch-Automation-Framework
- **Source framework:** suryavamsi3/EMS-Github-Master-Repo (Windows-Patch-Automation-Framework)
- **Key scripts:**
  - scripts/Invoke-WindowsPatchAutomation.ps1
  - scripts/Guest/Invoke-WindowsUpdate.ps1
  - scripts/Modules/VCenter.GuestOps.psm1

---

*End of manual*
