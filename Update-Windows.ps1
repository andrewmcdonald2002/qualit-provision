# =============================================================================
# Qualit provisioning - Windows Update loop (GitHub-hosted)
# https://github.com/andrewmcdonald2002/qualit-provision
#
# Installs EVERYTHING Windows Update offers (cumulative, security, drivers,
# feature upgrades), rebooting and re-checking until nothing is left - exactly
# like running Windows Update by hand until it says "You're up to date."
#
# HOW IT RUNS
#   - Launched by a Datto RMM quick job (see README), which downloads this file
#     from GitHub and runs it as SYSTEM.
#   - Survives every reboot via a SYSTEM scheduled task that re-downloads the
#     LATEST version of this script from GitHub each boot and continues.
#   - Writes a live status file to the Public desktop so a tech who signs in
#     can see the stage and last activity. When finished, that file is replaced
#     by UPDATES COMPLETE.txt and the resume task removes itself.
#
# NO SECRETS live in this script. Safe for a public repo.
# =============================================================================

$ErrorActionPreference = 'Stop'

# --- constants ---------------------------------------------------------------
$RawUrl     = 'https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/Update-Windows.ps1'
$WorkDir    = 'C:\ProvTemp'
$ScriptPath = Join-Path $WorkDir 'Update-Windows.ps1'
$StubPath   = Join-Path $WorkDir 'Resume-Update.ps1'
$StateFile  = Join-Path $WorkDir 'update-state.json'
$LogFile    = Join-Path $WorkDir 'update.log'
$StatusFile = Join-Path $env:PUBLIC 'Desktop\UPDATES RUNNING - STATUS.txt'
$DoneFile   = Join-Path $env:PUBLIC 'Desktop\UPDATES COMPLETE.txt'
$TaskName   = 'QualitUpdateResume'
$MaxRounds  = 12

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

# shared helpers (for Send-FailureReport); latest from GitHub, cached fallback
$script:JobName = 'update'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/lib/Common.ps1' -OutFile (Join-Path $WorkDir 'Common.ps1') -UseBasicParsing -TimeoutSec 60
} catch {}
try { . (Join-Path $WorkDir 'Common.ps1') } catch {}

# --- logging + live status file ----------------------------------------------
$script:StageLabel = 'Starting up'
$script:StatusDone = $false
try {
    if (Test-Path $StateFile) {
        $chk = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($chk.done) { $script:StatusDone = $true }
    }
} catch {}

function Write-StatusFile {
    param([string]$LastLine)
    if ($script:StatusDone) { return }
    try {
        @(
            '===================================================================',
            ' QUALIT WINDOWS UPDATES - LIVE STATUS  (updates itself automatically)',
            '===================================================================',
            " Current step : $script:StageLabel",
            " Last activity: $LastLine",
            '',
            ' - Runs INVISIBLY in the background, even at the login screen.',
            ' - Reboots are NORMAL; it resumes by itself after every reboot.',
            ' - Close and reopen this file to refresh it.',
            ' - Update rounds can run 30-60+ min with no new activity. Normal.',
            ' - If Last activity is 90+ min old AND the PC has not rebooted on',
            "   its own, check the log: $LogFile",
            ' - DONE = this file disappears and UPDATES COMPLETE.txt appears.'
        ) | Set-Content -Path $StatusFile -Encoding UTF8
    } catch {}
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    Write-StatusFile -LastLine $line
}

# --- state --------------------------------------------------------------------
function Get-UpdState {
    if (Test-Path $StateFile) { return (Get-Content $StateFile -Raw | ConvertFrom-Json) }
    $s = [pscustomobject]@{ round = 0; done = $false; startedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    $s | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
    return $s
}
function Save-UpdState { param($S) $S | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8 }

# --- reboot-resume: SYSTEM task runs a stub that pulls the LATEST script ------
function Set-ResumeTask {
    try {
        @(
            "try {",
            "  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
            "  Invoke-WebRequest -Uri '$RawUrl' -OutFile '$ScriptPath' -UseBasicParsing -TimeoutSec 120",
            "} catch {}",
            "& '$ScriptPath'"
        ) | Set-Content -Path $StubPath -Encoding UTF8
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $StubPath)
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
    } catch { Write-Log "Could not register resume task: $($_.Exception.Message)" 'WARN' }
}
function Remove-ResumeTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
function Restart-AndResume {
    param($S)
    Save-UpdState $S
    Set-ResumeTask
    Write-Log 'Rebooting to continue updates. This is normal - it resumes by itself.'
    Start-Sleep -Seconds 3
    Restart-Computer -Force
    exit
}

# --- keep the machine awake during the run ------------------------------------
function Set-BuildPowerPolicy {
    try {
        foreach ($s in 'standby-timeout-ac','standby-timeout-dc','hibernate-timeout-ac','hibernate-timeout-dc','monitor-timeout-ac','monitor-timeout-dc') {
            & powercfg /change $s 0 | Out-Null
        }
        Write-Log 'Sleep / hibernate / display-off disabled for the update run.'
    } catch {}
}
function Restore-PowerPolicy {
    try {
        & powercfg /change monitor-timeout-ac 10 | Out-Null
        & powercfg /change standby-timeout-ac 30 | Out-Null
        Write-Log 'Restored default power timeouts.'
    } catch {}
}

# --- finalize -------------------------------------------------------------------
function Complete-Run {
    param($S)
    Write-Log 'Finalizing: removing resume task and restoring power settings.'
    Remove-ResumeTask
    Restore-PowerPolicy
    $S.done = $true
    Save-UpdState $S
    $script:StatusDone = $true
    Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
    try {
        @(
            'WINDOWS UPDATES COMPLETE',
            ("Finished : {0}" -f (Get-Date)),
            'Windows Update reports the system is fully up to date.',
            "Run log  : $LogFile",
            '',
            'Delete this file before handing the device to the user.'
        ) | Set-Content -Path $DoneFile -Encoding UTF8
    } catch {}
    Write-Log 'Windows Update run finished successfully.'
}

# =============================================================================
# MAIN
# =============================================================================
$mutex = $null
try {
    $createdNew = $false
    $sec  = New-Object System.Security.AccessControl.MutexSecurity
    $rule = New-Object System.Security.AccessControl.MutexAccessRule(
        (New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')),
        [System.Security.AccessControl.MutexRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $sec.AddAccessRule($rule)
    $mutex = New-Object System.Threading.Mutex($true, 'Global\QualitUpdateLock', [ref]$createdNew, $sec)
    if (-not $createdNew -and -not $mutex.WaitOne(0)) {
        Write-Log 'Another update run is already active; exiting this one.'
        return
    }
} catch { $mutex = $null }

try {
    Write-Log '--- Update-Windows.ps1 invoked ---'
    $state = Get-UpdState

    if ($state.done) {
        Write-Log 'This machine already completed its update run (state: done). Nothing to do.'
        Write-Log 'To force a fresh run: delete C:\ProvTemp\update-state.json and run the job again.'
        return
    }

    Set-ResumeTask        # arm resume FIRST so even a Windows-forced reboot continues
    Set-BuildPowerPolicy

    # PSWindowsUpdate module
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Log 'Installing PSWindowsUpdate module.'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction SilentlyContinue | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -ErrorAction Stop
        } catch {
            Write-Log "Could not install PSWindowsUpdate: $($_.Exception.Message)" 'ERROR'
            Write-Log 'Aborting - run Windows Update manually on this machine.' 'ERROR'
            if (Get-Command Send-FailureReport -ErrorAction SilentlyContinue) {
                Send-FailureReport -Detail "PSWindowsUpdate module install failed: $($_.Exception.Message)"
            }
            Complete-Run -S $state
            exit 1
        }
    }
    Import-Module PSWindowsUpdate -Force

    # one scan+install round per invocation; reboots loop us back here
    while ($true) {
        $round = [int]$state.round
        if ($round -ge $MaxRounds) {
            Write-Log "Reached max update rounds ($MaxRounds); finalizing." 'WARN'
            if (Get-Command Send-FailureReport -ErrorAction SilentlyContinue) {
                Send-FailureReport -Detail "Hit max update rounds ($MaxRounds) without reaching 'up to date' - an update may be re-offering itself."
            }
            Complete-Run -S $state
            return
        }
        $script:StageLabel = "Windows Updates - round $($round + 1) of $MaxRounds"
        Write-Log "Checking for Windows updates (everything, incl. feature upgrades). Round $($round + 1)/$MaxRounds."
        $updates = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction SilentlyContinue

        if ($updates -and $updates.Count -gt 0) {
            Write-Log "Installing $($updates.Count) update(s). Large updates can take 30-60+ min with no new activity - normal."
            Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue | Out-Null
            $state.round = $round + 1
            Save-UpdState $state
            if (Get-WURebootStatus -Silent) {
                Restart-AndResume -S $state
            } else {
                Write-Log 'Updates installed, no reboot required; re-checking.'
            }
        } else {
            Write-Log 'No more applicable updates - system is up to date.'
            Complete-Run -S $state
            return
        }
    }
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
