# qualit-provision

Qualit (QCC) PC provisioning scripts, hosted here so Datto RMM always runs the
**latest version** — edit here once, every future machine gets it. No secrets
live in this repo: passwords arrive at runtime via Datto job variables.

## The flow (replaces the old all-in-one USB script)

1. **OOBE** (offline): create the local `Admin` account with the
   `Shift+F10` -> `start ms-cxh:localonly` trick. Connect network after.
2. **Install the site-specific Datto agent** — the ONLY thing on the provision
   thumb drive (or download it from the Datto portal). Machine lands in the
   right client site automatically.
3. **Datto quick job: "Provision - Name + Accounts"** — renames the PC, sets the
   Admin password, creates the standard `User` account. Reboots to apply.
4. **Datto quick job: "Provision - Windows Updates"** — installs EVERYTHING
   Windows Update offers, looping through reboots until up to date. Runs in the
   background via a SYSTEM scheduled task that re-downloads the latest script
   from this repo on every boot.
5. Datto app installs (Chrome/Acrobat/Office/Zoom) + the config components
   (default apps, taskbar, Windows Security) + final reboot.

## Files

| File | What it is |
|---|---|
| `Update-Windows.ps1` | The update loop. Downloaded and run on the machine; survives reboots; writes a live status file to the desktop. |
| `Set-NameAndAccounts.ps1` | Rename + Admin/User accounts. Expects `PCName` and `AdminPassword` env vars (Datto variables). |
| `datto-runner-updates.ps1` | PASTE THIS into the Datto component "Provision - Windows Updates". Downloads Update-Windows.ps1, arms the resume task, starts it, returns immediately. |
| `datto-runner-name-accounts.ps1` | PASTE THIS into the Datto component "Provision - Name + Accounts". Add the two variables below. |

## Datto component setup

### Provision - Name + Accounts
- Components -> New Component -> Scripts, PowerShell.
- Paste `datto-runner-name-accounts.ps1`.
- Add **Input Variables**: `PCName` (text) and `AdminPassword` (text/masked).
  Datto passes variables to the script as environment variables.
- Run as LocalSystem. The job reboots the machine at the end (rename).

### Provision - Windows Updates
- Components -> New Component -> Scripts, PowerShell.
- Paste `datto-runner-updates.ps1`. No variables.
- Run as LocalSystem. The job returns in seconds; updates continue in the
  background through as many reboots as needed.

## How a tech knows the updates are running / done

- Desktop file **`UPDATES RUNNING - STATUS.txt`** — live status: current round,
  last activity timestamp. Reboots are normal. Update rounds can be silent for
  30-60+ min.
- Done = that file disappears and **`UPDATES COMPLETE.txt`** appears.
- Full log: `C:\ProvTemp\update.log`.
- Stuck? Last activity 90+ min old with no self-reboot -> check the log.
- Re-running the updates job on a finished machine exits immediately by design.
  To force a fresh run: delete `C:\ProvTemp\update-state.json` and re-run.

## Editing / maintaining

Push to `main`. Machines always pull
`https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/...`
at job start AND at every resume boot, so fixes take effect immediately —
even for a machine mid-update-run.
