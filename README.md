# Windows Patch Automation Framework

Production-oriented, convergent Windows patch orchestration using GitHub Actions,
VMware PowerCLI, and the vCenter Guest Operations API. Windows Update is driven
inside each guest with the native Windows Update Agent COM API.

## Design guarantees

- GitHub Actions is the orchestration and audit boundary.
- `Invoke-VMScript` and `Copy-VMGuestFile` are the only mechanisms used to
  interact with guests. The framework does not use WinRM, PowerShell Remoting,
  RDP, SMB, SSH, GUI automation, or direct guest network connectivity.
- Credentials come from GitHub environment/repository secrets and are never
  stored in configuration, inventory, command-line arguments, or reports.
- Every VM is an isolated worker. A failure does not stop other VM workers.
- Each worker repeatedly scans and patches until no applicable updates remain,
  or the configured safety cap is reached.

## Architecture

1. `.github/workflows/windows-patch.yml` validates the framework and starts the
   patch job on a controlled self-hosted Windows runner.
2. `scripts/Invoke-WindowsPatchAutomation.ps1` validates configuration and
   inventory, then processes VMs concurrently with a throttle limit.
3. `scripts/Modules/VCenter.GuestOps.psm1` connects to vCenter, verifies VM and
   VMware Tools state, stages the guest script, starts it, polls for completion,
   collects artifacts, and coordinates restarts.
4. `scripts/Guest/Invoke-WindowsUpdate.ps1` runs locally as administrator inside
   Windows. It uses `Microsoft.Update.Session` to scan, accept EULAs, download,
   and install updates.
5. The orchestrator produces per-VM JSON Lines logs, a merged master log, and
   CSV, HTML, and JSON compliance reports. GitHub uploads the entire output tree.

The runner needs HTTPS access to vCenter and PowerShell Gallery during module
installation. It does not need network access to Windows guest management ports.
The guests need their normal configured path to WSUS or Microsoft Update.

## Prerequisites

- vCenter and ESXi versions supported by VMware PowerCLI 13.3.
- VMware Tools installed, running, and healthy on every target VM.
- A self-hosted Windows GitHub Actions runner labeled `self-hosted`, `windows`,
  and `vcenter`, with PowerShell 7.2 or later and network access to vCenter.
- A vCenter service account with least-privilege permissions for:
  - Virtual machine inventory read
  - Guest Operations modifications, queries, and program execution
- A Windows guest service account that is a local administrator on targets and
  has logon rights required by VMware Guest Operations.
- Windows Update Agent configured and able to reach the approved update source.
- A GitHub environment named `windows-patching`; production approval rules are
  strongly recommended.

## Setup

1. Clone this repository and update `config/settings.json` and `config/vms.csv`.
2. Update `config/settings.json`, especially `vCenterServer`, certificate policy,
   throttle, safety cap, and timeouts.
3. Replace the disabled example in `config/vms.csv`. Set `Enabled` to `true`
   only for systems approved for the maintenance window.
4. Create these encrypted secrets in the `windows-patching` GitHub environment:

   - `VCENTER_USERNAME`
   - `VCENTER_PASSWORD`
   - `WINDOWS_GUEST_USERNAME`
   - `WINDOWS_GUEST_PASSWORD`

5. Ensure the runner labels and workflow schedule match your environment.
6. Run the workflow manually against a small non-production cohort before
   enabling the schedule.

The inventory schema is:

- `VMName` (required): exact, unique vCenter inventory name.
- `Enabled` (required): `true`, `yes`, or `1` enables a row.
- `VCenterServer` (optional): per-VM override; blank uses the setting.
- `Environment`, `Owner`, `MaintenanceWindow`: governance metadata.

## Configuration

`config/settings.json` controls:

- `ignoreInvalidCertificate`: keep `false` in production. Import the vCenter CA
  chain into the runner trust store rather than bypassing validation.
- `guestWorkingDirectory`: protected staging location inside each guest.
- `windowsUpdateSearchCriteria`: native WUA search expression.
- `autoRebootWhenRequired`: when `true`, automatically reboots guests after updates
  that require a restart and continues scanning until no updates remain.
- `maxPatchCycles`: convergence safety cap.
- `throttleLimit`: maximum simultaneous VM workers. Each worker has its own
  vCenter connection.
- `pollIntervalSeconds`: Guest Operations polling interval.
- `timeouts`: PowerCLI web operation, initial Tools readiness, patch cycle, and
  reboot readiness limits.
- `retry`: exponential-backoff attempt count and initial delay.

Tune concurrency against vCenter capacity and update infrastructure. Start low.

## Execution behavior

For each enabled VM the framework:

1. Connects to the selected vCenter using the secret service account.
2. Resolves exactly one VM and requires `PoweredOn`.
3. Waits for `guestToolsRunning` and a running guest state.
4. Creates the protected guest work directory and copies the patch engine.
5. Launches one update cycle asynchronously through Guest Operations.
6. Polls a result file until the cycle timeout, then retrieves guest logs/results.
7. If required, restarts Windows locally through Guest Operations and waits until
   VMware Tools first goes unavailable and then returns healthy.
8. Repeats until a scan finds zero applicable updates.
9. Marks the VM `MaxCyclesExceeded` if convergence exceeds the safety cap.

Transient connect, discovery, staging, start, and artifact-copy operations use
bounded exponential retries. Patch and readiness waits have explicit deadlines.

## Outputs

Each run is stored under `output/<run-id>/`:

- `master.jsonl`: run envelope plus all per-VM structured logs.
- `compliance-report.csv`: concise compliance export.
- `compliance-report.html`: human-readable report.
- `compliance-report.json`: full machine-readable results and update details.
- `vm-logs/<vm>/orchestrator.jsonl`: per-VM orchestration log.
- `vm-logs/<vm>/cycle-*-guest.jsonl`: guest Windows Update logs.
- `vm-logs/<vm>/cycle-*-result.json`: raw guest cycle results.

The workflow summary includes fleet counts and a VM status table. Reports are
uploaded even when patching fails. With `-FailOnNonCompliance`, the patch step
fails only after reports and summary are generated.

## Local validation

Static and unit tests do not require vCenter or Windows:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
```

A real acceptance test must still be performed against a disposable Windows VM
with a snapshot/backup and approved maintenance window. See `TROUBLESHOOTING.md`
and `SECURITY.md` before production rollout.
