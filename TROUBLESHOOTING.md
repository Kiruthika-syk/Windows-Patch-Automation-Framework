# Troubleshooting

Always download the workflow artifact first. Start with `master.jsonl`, then use
the VM's `orchestrator.jsonl` and latest guest cycle result/log.

## VM not found or ambiguous

- Confirm `VMName` exactly matches the vCenter inventory name.
- Remove duplicate enabled inventory rows.
- If linked/multiple vCenters contain the same name, set `VCenterServer` on the
  inventory row and ensure that endpoint resolves a single object.
- Verify service-account inventory permissions.

## VMware Tools readiness timeout

- Confirm the VM is powered on and Tools is installed/running.
- Inspect `Guest.ToolsRunningStatus` and `Guest.GuestState` in vCenter.
- Repair or upgrade Tools if stale.
- After a long reboot, increase `timeouts.rebootSeconds`; do not remove the
  readiness gate.

## Guest authentication or operation denied

- Verify the guest account secret independently of the vCenter account.
- Confirm the account is an administrator and is permitted by local/domain logon
  policy for VMware Guest Operations.
- Check VMware Tools and Windows event logs for guest operation failures.
- Review UAC remote restrictions and service-account policies.

## PowerCLI connection or certificate failure

- Use the configured vCenter FQDN and verify DNS/time synchronization.
- Install the issuing CA chain on the runner.
- Keep `ignoreInvalidCertificate` false in production.
- Confirm TCP 443 from the runner to vCenter and inspect proxy/firewall policy.

## Patch cycle timeout

- Check the cycle guest JSONL log for the last completed stage.
- Review Windows Update Client operational events and WSUS health.
- Ensure sufficient disk space and that no installer is waiting for interaction.
- Increase `timeouts.patchCycleSeconds` only after identifying normal long-running
  behavior. The orchestrator attempts to stop the timed-out process.

## Update download or installation failure

The raw cycle result records operation result codes and HRESULT values. Decode
the HRESULT using Microsoft Windows Update documentation, then validate:

- WSUS/Microsoft Update connectivity and policy.
- Windows Update, BITS, Cryptographic Services, and TrustedInstaller state.
- Servicing stack health (`DISM /Online /Cleanup-Image /ScanHealth`).
- Disk capacity, pending servicing operations, and update applicability.

`SucceededWithErrors` is accepted only when every per-update result succeeded;
any failed update makes the VM non-compliant.

## MaxCyclesExceeded

The VM continued finding updates after `maxPatchCycles`. This can be normal for
old images with prerequisite chains, but the cap prevents endless runs. Review
cycle results, reboot state, WSUS approvals, and servicing-stack requirements.
Raise the cap only through change review.

## Reports missing after a failed run

The upload step uses `if: always()`. If no artifact exists:

- Check whether validation failed before the patch job.
- Check self-hosted runner disk permissions and free space.
- Verify the output path was not changed without updating the workflow.

## Local diagnostic command

Run configuration/static tests without infrastructure:

```powershell
Invoke-Pester ./tests -Output Detailed
```

Do not place real credentials in local scripts, test fixtures, shell history, or
support bundles.
