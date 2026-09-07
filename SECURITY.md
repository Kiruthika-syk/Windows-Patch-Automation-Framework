# Security guidance

## Credential handling

- Store vCenter and guest credentials only as encrypted secrets in the protected
  `windows-patching` GitHub environment.
- Require environment reviewers and restrict deployment branches/tags.
- Never enable PowerShell transcript or shell debug tracing on the credential
  injection step. Do not print credential objects or environment variables.
- Use dedicated, non-interactive service accounts. Do not use personal accounts.
- Rotate both accounts regularly and immediately after suspected exposure.
- Prefer a password vault integration with short-lived credentials if supported
  by organizational policy; map retrieved values to the documented environment
  variables only for the patch process.

vCenter authentication and Windows guest authentication are separate security
boundaries. Guest Operations requires guest credentials; vCenter credentials do
not grant a Windows logon by themselves.

## Least privilege

Create a vCenter role scoped only to target VM folders/resource groups. Grant
inventory read plus the Guest Operations privileges needed to query, transfer
files, and execute programs. Do not grant datastore, host, network, snapshot,
power-control, or administrator privileges unless separately justified.

Scope the Windows account to target servers. It must be locally privileged
because Windows Update installation requires elevation, but it should be denied
interactive and remote desktop logon where policy allows. Monitor its use.

## Runner hardening

- Use an ephemeral or dedicated self-hosted runner, isolated from untrusted jobs.
- Never run pull-request code from forks on the privileged runner.
- Restrict outbound access to vCenter, GitHub endpoints, and the approved module
  repository. The runner does not require guest WinRM/RDP/SMB access.
- Pin reviewed module/action versions and periodically update them deliberately.
- Protect runner registration tokens and remove stale runners.
- Forward runner, vCenter, and Windows security logs to the SIEM.

## Transport and certificates

Keep `ignoreInvalidCertificate` set to `false`. Install the enterprise CA chain
on the runner and use the vCenter FQDN represented in its certificate. Bypassing
certificate validation exposes credentials and Guest Operations to interception.

## Guest artifacts

The guest work directory contains scripts and logs but no credentials. Restrict
its ACL to Administrators and SYSTEM according to your server baseline. Establish
a cleanup/retention policy after evidence collection. Reports may reveal host
names, update history, KB identifiers, and operational errors; treat artifacts
as internal security data and apply repository/artifact retention controls.

## Supply-chain controls

Review changes to workflow, scripts, inventory, and settings through branch
protection and CODEOWNERS. Pin GitHub Actions to immutable commit SHAs if required
by policy. Mirror and sign PowerCLI/Pester modules in an internal repository for
high-assurance environments. Validate module hashes before deployment.

## Operational safety

- Test in non-production and verify backups before the first fleet run.
- Use small cohorts and conservative throttles.
- Align workflow dispatch/schedule with approved maintenance windows.
- Treat `MaxCyclesExceeded`, update failures, and reboot readiness timeouts as
  non-compliant outcomes requiring review; do not silently suppress them.
- The framework does not create snapshots. Integrate snapshot/backup controls as
  a separately reviewed process if your change policy requires them.
