# qualit-provision

Qualit (QCC) PC provisioning, broken into **four independent Datto RMM quick
jobs** that each pull their latest script from this repo at run time. Edit here
once - every future machine gets it. **No secrets live in this repo**; passwords
arrive at runtime via Datto job variables.

Every job **verifies its own work**: if the machine doesn't match the goal
afterward, the job exits 1 (Datto shows FAILED) and POSTs a failure report -
computer, job, error, log tail - to `https://provision.qualit.com/api/report`
for alerting and automated diagnosis.

## The flow

1. **OOBE** (offline): local `Admin` via `Shift+F10` -> `start ms-cxh:localonly`.
   Connect network after. Install the **site-specific Datto agent** - the only
   thing on the provision thumb drive (or download from the Datto portal).
2. Quick job **Provision - Name + Accounts** (rename + Admin password; reboots)
3. Quick job **Provision - Windows Updates** (background loop until up to date)
4. Datto app installs: Chrome / Acrobat / Office / Zoom
5. Quick job **Provision - User Experience** (User account + taskbar + defaults)
6. Quick job **Provision - Windows Security** (+ reboot to engage Core Isolation)

## Files

| File | What it is |
|---|---|
| `lib/Common.ps1` | Shared logging, verification, failure reporting. Every job downloads it. |
| `Set-NameAndAccounts.ps1` | Rename + Admin account. Vars: `PCName`, `AdminPassword`. Reboots. |
| `Update-Windows.ps1` | Update loop; SYSTEM resume task re-pulls latest each boot; desktop status file. |
| `Set-UserExperience.ps1` | `User` account + taskbar pins + Chrome/Acrobat defaults. Run AFTER apps. |
| `Set-WindowsSecurity.ps1` | SmartScreen/PUA, Core Isolation (VBS+HVCI+kernel stacks), OneDrive nag, account card. Reboot after. |
| `datto-runner-*.ps1` | PASTE these into the matching Datto component. |

## Datto component setup

One component per runner file (Scripts, PowerShell, run as LocalSystem):

| Component name | Paste | Variables |
|---|---|---|
| Provision - Name + Accounts | `datto-runner-name-accounts.ps1` | `PCName` (text), `AdminPassword` (masked) |
| Provision - Windows Updates | `datto-runner-updates.ps1` | none |
| Provision - User Experience | `datto-runner-userexperience.ps1` | none |
| Provision - Windows Security | `datto-runner-windowssecurity.ps1` | none |

## Job results

- **Success** = job StdOut ends `JOB OK - all verifications passed.` (exit 0)
- **Failure** = exit 1, Datto shows FAILED, and the failure was reported to
  provision.qualit.com. Each VERIFY line in StdOut shows exactly which check
  failed.
- Updates job: returns in seconds; progress on the desktop
  (`UPDATES RUNNING - STATUS.txt` -> `UPDATES COMPLETE.txt`), log at
  `C:\ProvTemp\update.log`. Re-running on a finished machine exits immediately;
  force a fresh run by deleting `C:\ProvTemp\update-state.json`.

## Maintaining

Push to `main` - machines pull the raw URLs at every job start and resume boot,
so fixes take effect immediately, even mid-update-run. Keep scripts ASCII and
secret-free (public repo).
