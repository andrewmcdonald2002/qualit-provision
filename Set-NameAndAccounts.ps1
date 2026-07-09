# =============================================================================
# Qualit provisioning - JOB: rename PC + Admin account
# https://github.com/andrewmcdonald2002/qualit-provision
#
# Datto quick job with INPUT VARIABLES:
#   PCName        - computer name to assign (e.g. QCC-LT-014)
#   AdminPassword - password for the local Admin account
#
# The standard 'User' account is NOT created here - that belongs to the
# "User Experience" job. This job: Admin account + rename + reboot.
# Verifies its own work; exits 1 (Datto FAILED) and reports to
# provision.qualit.com if anything didn't stick.
# =============================================================================

$ErrorActionPreference = 'Stop'
$script:JobName = 'name-accounts'

# --- shared helpers (download latest, fall back to cached) --------------------
$common = 'C:\ProvTemp\Common.ps1'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/lib/Common.ps1' -OutFile $common -UseBasicParsing -TimeoutSec 60
} catch {}
. $common

$PCName  = $env:PCName
$AdminPw = $env:AdminPassword
if ([string]::IsNullOrWhiteSpace($PCName))  { Write-JobLog 'PCName variable not set on the job.' 'ERROR';  Send-FailureReport -Detail 'PCName variable missing'; exit 1 }
if ([string]::IsNullOrWhiteSpace($AdminPw)) { Write-JobLog 'AdminPassword variable not set on the job.' 'ERROR'; Send-FailureReport -Detail 'AdminPassword variable missing'; exit 1 }

# --- Admin account -------------------------------------------------------------
try {
    $sec = ConvertTo-SecureString $AdminPw -AsPlainText -Force
    if (Get-LocalUser -Name 'Admin' -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name 'Admin' -Password $sec -PasswordNeverExpires $true
        Write-JobLog 'Admin: password set on existing account.'
    } else {
        New-LocalUser -Name 'Admin' -Password $sec -PasswordNeverExpires $true | Out-Null
        Write-JobLog 'Admin: account created.'
    }
    if (-not (Get-LocalGroupMember -Group 'Administrators' -Member 'Admin' -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group 'Administrators' -Member 'Admin'
    }
    Write-JobLog 'Admin: in Administrators group.'
} catch {
    Write-JobLog "Admin account step failed: $($_.Exception.Message)" 'ERROR'
}

# --- rename ---------------------------------------------------------------------
$renamePending = $false
try {
    if ($env:COMPUTERNAME -ieq $PCName) {
        Write-JobLog "Rename: already named $PCName."
    } else {
        Rename-Computer -NewName $PCName -Force
        $renamePending = $true
        Write-JobLog "Rename: $($env:COMPUTERNAME) -> $PCName (applies on reboot)."
    }
} catch {
    Write-JobLog "Rename failed: $($_.Exception.Message)" 'ERROR'
}

# --- verify ----------------------------------------------------------------------
$pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
$checks = @(
    @{ name = 'Admin account exists';        ok = [bool](Get-LocalUser -Name 'Admin' -ErrorAction SilentlyContinue) },
    @{ name = 'Admin is an administrator';   ok = [bool](Get-LocalGroupMember -Group 'Administrators' -Member 'Admin' -ErrorAction SilentlyContinue) },
    @{ name = "Computer name set to $PCName"; ok = ($pendingName -ieq $PCName) }
)

$failedCount = @($checks | Where-Object { -not $_.ok }).Count
if ($failedCount -eq 0 -and $renamePending) {
    Write-JobLog 'All checks passed. Rebooting in 20 seconds to apply the rename.'
    shutdown.exe /r /t 20 /c 'Qualit provisioning - applying computer rename'
}
Complete-Job -Checks $checks
