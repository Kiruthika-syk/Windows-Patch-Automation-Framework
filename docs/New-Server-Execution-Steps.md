# New Server — Execution Steps

Operator guide for onboarding and patching a **new Windows VM** on Stryker vCenter using this framework.

## Before you start

Collect the following before adding a server:

| Item | Why it matters |
|------|----------------|
| **VM name in vCenter** (exact spelling) | Framework resolves the VM by name |
| **IP address** | Used when the inventory name differs from vCenter or for validation |
| **vCenter server** | BLR: `blr-vsphere-01.strykercorp.com` |
| **Guest username** | Often `Administrator` or `admin` — not always the same across VMs |
| **Guest password** | Must work via **Guest Operations**, not only RDP |
| **VM powered on + VMware Tools running** | Required for automation |

**Rule:** Use one guest password per patch run. Batch only VMs that share the same guest credentials.

---

## Path A — Automated patch (recommended)

Run from the Linux automation host (`blr-kiruthika`):

```bash
cd /home/tpx-admin/.cursor-server/Windows-Patch-Automation-Framework
```

### 1. Snapshot the VM

In vCenter: select the VM → **Snapshots → Take Snapshot** before patching.

### 2. Create a single-VM inventory file

Create `output/new-server-only.csv`:

```csv
VMName,Enabled,VCenterServer,Environment,Owner,MaintenanceWindow,IPAddress,FQDN,Notes
YOUR-VM-NAME,true,blr-vsphere-01.strykercorp.com,BLR,OwnerName,Sunday-0200-UTC,10.90.x.x,your-vm.fqdn.com,New server - first patch
```

Replace `YOUR-VM-NAME`, IP, and FQDN. Credentials go in the cred file, **not** in the CSV.

### 3. Set credentials

Create or edit `~/.windows_patch_creds`:

```bash
export VCENTER_USERNAME='your-vcenter-user'
export VCENTER_PASSWORD='your-vcenter-password'
export WINDOWS_GUEST_USERNAME='Administrator'
export WINDOWS_GUEST_PASSWORD='your-guest-password'
```

Load credentials:

```bash
source ~/.windows_patch_creds
```

### 4. Validate (read-only)

```bash
pwsh -File ./scripts/Validate-PatchEnvironment.ps1 \
  -InventoryPath ./output/new-server-only.csv
```

Expect:

- vCenter connected
- VM found
- VMware Tools running
- Guest credential test succeeds (`GuestHost=` shows hostname)

Reports: `output/validation/`

Fix any validation failure before patching.

### 5. Patch

```bash
./scripts/execute_repair_and_patch.sh ./output/new-server-only.csv
```

The run will repair Windows Update COM if needed, install updates, reboot when required, and repeat until **Compliant** or the safety cap is reached.

### 6. Review results

```bash
ls -lt output/ | head
```

In the latest `output/<run-id>/` folder:

| File | Purpose |
|------|---------|
| `compliance-report.html` | Operator summary |
| `compliance-report.csv` | Spreadsheet export |
| `vm-logs/<vm>/orchestrator.jsonl` | Per-VM detail log |

**Success:** status **Compliant**, zero pending updates.

### 7. Add to main inventory

After success, add the row to `config/vms.csv` (or set `Enabled=true`).

---

## Path B — Manual patch from your workstation (RDP)

Use when you prefer hands-on control or guest automation credentials are not ready.

### 1. Snapshot in vCenter

Same as Path A step 1.

### 2. RDP to the server

```text
mstsc /v:10.90.x.x
```

Log in with the local admin account (`Administrator` or `admin`).

### 3. Windows Update

1. Open **Settings → Windows Update → Check for updates**
2. Install all security and important updates
3. Reboot when prompted
4. Repeat until **You're up to date**

### 4. Verify zero pending updates (elevated PowerShell)

```powershell
$Session = New-Object -ComObject Microsoft.Update.Session
$Searcher = $Session.CreateUpdateSearcher()
$Result = $Searcher.Search("IsInstalled=0 and IsHidden=0")
$Result.Updates.Count
```

Expected result: `0`

### 5. Optional — confirm from automation host

```bash
source ~/.windows_patch_creds
pwsh -File ./scripts/Validate-PatchEnvironment.ps1 \
  -InventoryPath ./output/new-server-only.csv
```

---

## Common failures

| Error | Likely cause | Fix |
|-------|--------------|-----|
| Guest credential auth failed | Wrong user or password | Confirm RDP login; update cred file |
| VM not found | Name typo or wrong vCenter | Copy exact name from vCenter; add IP to CSV |
| Tools not running | VMware Tools stopped | Start or reinstall Tools |
| WU COM `0x800703FA` | Broken Windows Update agent | Run automated repair script or DISM/SFC on guest |
| IP mismatch | Spreadsheet IP ≠ vCenter IP | Use IP from vCenter guest summary |

---

## Quick checklist

1. Snapshot VM
2. Create `output/new-server-only.csv`
3. Set guest creds in `~/.windows_patch_creds`
4. Validate
5. Patch (automated or manual)
6. Confirm Compliant / zero pending
7. Add to `config/vms.csv`

---

See also: [Process-Flow-and-Mechanism.md](./Process-Flow-and-Mechanism.md), [Windows-Patch-Automation-Manual.md](./Windows-Patch-Automation-Manual.md), [TROUBLESHOOTING.md](../TROUBLESHOOTING.md).
