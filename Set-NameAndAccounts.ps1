# =============================================================================
# Qualit provisioning - rename PC + standard accounts (GitHub-hosted)
# https://github.com/andrewmcdonald2002/qualit-provision
#
# Run via a Datto RMM quick job with two INPUT VARIABLES (see README):
#   PCName        - the computer name to assign (e.g. QCC-LT-014)
#   AdminPassword - the password to set on the local Admin account
#
# Datto exposes component variables to the script as environment variables.
# NO SECRETS live in this script - the password arrives at runtime from Datto.
#
# Does:
#   1. Ensures local 'Admin' account exists (creates if missing), sets its
#      password, adds to Administrators, hides nothing - this is the tech account.
#   2. Ensures local 'User' account exists with NO password (standard user).
#   3. Renames the computer to PCName.
#   4. Reboots to apply the rename (required by Windows).
# =============================================================================

$ErrorActionPreference = 'Stop'

$PCName  = $env:PCName
$AdminPw = $env:AdminPassword

if ([string]::IsNullOrWhiteSpace($PCName))  { Write-Output 'ERROR: PCName variable not set on the job.';  exit 1 }
if ([string]::IsNullOrWhiteSpace($AdminPw)) { Write-Output 'ERROR: AdminPassword variable not set on the job.'; exit 1 }

# --- Admin account -----------------------------------------------------------
$sec = ConvertTo-SecureString $AdminPw -AsPlainText -Force
if (Get-LocalUser -Name 'Admin' -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name 'Admin' -Password $sec -PasswordNeverExpires $true
    Write-Output "Admin: password set on existing account."
} else {
    New-LocalUser -Name 'Admin' -Password $sec -PasswordNeverExpires $true | Out-Null
    Write-Output "Admin: account created."
}
if (-not (Get-LocalGroupMember -Group 'Administrators' -Member 'Admin' -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group 'Administrators' -Member 'Admin'
}
Write-Output 'Admin: in Administrators group.'

# --- User account (standard, no password) --------------------------------------
if (-not (Get-LocalUser -Name 'User' -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name 'User' -NoPassword | Out-Null
    Set-LocalUser -Name 'User' -PasswordNeverExpires $true
    Write-Output 'User: account created (no password).'
} else {
    Write-Output 'User: account already exists.'
}
if (-not (Get-LocalGroupMember -Group 'Users' -Member 'User' -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group 'Users' -Member 'User' -ErrorAction SilentlyContinue
}

# --- rename + reboot ------------------------------------------------------------
if ($env:COMPUTERNAME -ieq $PCName) {
    Write-Output "Rename: computer is already named $PCName. No reboot needed."
} else {
    Rename-Computer -NewName $PCName -Force
    Write-Output "Rename: $($env:COMPUTERNAME) -> $PCName. Rebooting in 15 seconds to apply."
    shutdown.exe /r /t 15 /c "Qualit provisioning - applying computer rename"
}
