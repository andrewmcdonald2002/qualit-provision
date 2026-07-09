# =============================================================================
# Qualit provisioning - JOB: Windows Security hardening
# https://github.com/andrewmcdonald2002/qualit-provision
#
# Does:
#   1. App and Browser control: SmartScreen + PUA blocking (apps + downloads).
#   2. Core Isolation: VBS + Memory Integrity (HVCI) + Kernel-mode
#      Hardware-enforced Stack Protection. REQUIRES A REBOOT to engage.
#   3. Hides the OneDrive "ransomware data recovery" nag (machine-wide policy).
#   4. Dismisses the Account-protection card for new users (Active Setup).
#
# Verifies registry state; exits 1 + reports to provision.qualit.com on failure.
# Reboot the machine after this job (Datto post-job reboot or the next job).
# =============================================================================

$ErrorActionPreference = 'SilentlyContinue'
$script:JobName = 'windows-security'

$common = 'C:\ProvTemp\Common.ps1'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/lib/Common.ps1' -OutFile $common -UseBasicParsing -TimeoutSec 60
} catch {}
. $common

# --- 1. SmartScreen + PUA ------------------------------------------------------
$exp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
New-Item $exp -Force | Out-Null
Set-ItemProperty $exp -Name 'SmartScreenEnabled' -Value 'Warn' -Type String
try { Set-MpPreference -PUAProtection Enabled } catch {}
$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
New-Item $edge -Force | Out-Null
Set-ItemProperty $edge -Name 'SmartScreenEnabled'    -Value 1 -Type DWord
Set-ItemProperty $edge -Name 'SmartScreenPuaEnabled' -Value 1 -Type DWord
Write-JobLog 'SmartScreen + PUA (apps + downloads) enabled.'

# --- 2. Core Isolation: VBS + HVCI + kernel shadow stacks ------------------------
$dg = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
New-Item $dg -Force | Out-Null
Set-ItemProperty $dg -Name 'EnableVirtualizationBasedSecurity' -Value 1 -Type DWord
Set-ItemProperty $dg -Name 'RequirePlatformSecurityFeatures'   -Value 1 -Type DWord
$hvci = "$dg\Scenarios\HypervisorEnforcedCodeIntegrity"
New-Item $hvci -Force | Out-Null
Set-ItemProperty $hvci -Name 'Enabled'      -Value 1 -Type DWord
Set-ItemProperty $hvci -Name 'WasEnabledBy' -Value 0 -Type DWord
$ks = "$dg\Scenarios\KernelShadowStacks"
New-Item $ks -Force | Out-Null
Set-ItemProperty $ks -Name 'Enabled'      -Value 1 -Type DWord
Set-ItemProperty $ks -Name 'WasEnabledBy' -Value 0 -Type DWord
Write-JobLog 'Core Isolation keys set (VBS + Memory Integrity + Kernel Stack Protection). Effective after reboot.'

# --- 3. hide OneDrive ransomware-recovery nag -------------------------------------
$vtp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Virus and threat protection'
New-Item $vtp -Force | Out-Null
Set-ItemProperty $vtp -Name 'HideRansomwareRecovery' -Value 1 -Type DWord
Write-JobLog 'OneDrive ransomware-recovery nag hidden (all users).'

# --- 3b. hide the Account protection section entirely (machine-wide policy) --------
# Win11 26100+ shows a "Sign in with Microsoft" promo card that ignores the
# per-user dismissal value. Our fleet uses local accounts, so hide the whole
# section - same documented-policy approach as the OneDrive recovery nag.
$ap = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Account protection'
New-Item $ap -Force | Out-Null
Set-ItemProperty $ap -Name 'UILockdown' -Value 1 -Type DWord
Write-JobLog 'Account protection section hidden (all users).'

# --- 4. dismiss Account-protection card for new users ------------------------------
$asKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{8f3a1c20-3b21-4c2a-9f10-7ad2e0c50003}'
New-Item $asKey -Force | Out-Null
$state = 'HKCU\SOFTWARE\Microsoft\Windows Security Health\State'
$stub  = 'cmd /c "reg add \"' + $state + '\" /v AccountProtection_MicrosoftAccount_Disconnected /t REG_DWORD /d 0 /f"'
Set-ItemProperty $asKey -Name '(default)' -Value 'QCC Security dashboard dismissals'
Set-ItemProperty $asKey -Name 'StubPath'  -Value $stub -Type ExpandString
Set-ItemProperty $asKey -Name 'Version'   -Value '1,0,0,1' -Type String
try { reg add "HKCU\SOFTWARE\Microsoft\Windows Security Health\State" /v AccountProtection_MicrosoftAccount_Disconnected /t REG_DWORD /d 0 /f | Out-Null } catch {}
Write-JobLog 'Account-protection dismissal queued (Active Setup).'

Write-JobLog 'REBOOT REQUIRED to finish Core Isolation.'

# --- verify --------------------------------------------------------------------------
function Test-RegVal { param($Path,$Name,$Want) ((Get-ItemProperty $Path -ErrorAction SilentlyContinue).$Name -eq $Want) }
$checks = @(
    @{ name = 'SmartScreen (check apps and files) = Warn'; ok = (Test-RegVal $exp 'SmartScreenEnabled' 'Warn') },
    @{ name = 'Defender PUA protection enabled';           ok = ((Get-MpPreference -ErrorAction SilentlyContinue).PUAProtection -eq 1) },
    @{ name = 'Edge SmartScreen policy = 1';               ok = (Test-RegVal $edge 'SmartScreenEnabled' 1) },
    @{ name = 'Edge SmartScreen PUA policy = 1';           ok = (Test-RegVal $edge 'SmartScreenPuaEnabled' 1) },
    @{ name = 'VBS enabled';                               ok = (Test-RegVal $dg 'EnableVirtualizationBasedSecurity' 1) },
    @{ name = 'Memory Integrity (HVCI) key = 1';           ok = (Test-RegVal $hvci 'Enabled' 1) },
    @{ name = 'Kernel-mode Stack Protection key = 1';      ok = (Test-RegVal $ks 'Enabled' 1) },
    @{ name = 'OneDrive recovery nag hidden';              ok = (Test-RegVal $vtp 'HideRansomwareRecovery' 1) },
    @{ name = 'Account protection section hidden';         ok = (Test-RegVal $ap 'UILockdown' 1) },
    @{ name = 'Account-protection Active Setup armed';     ok = (Test-Path $asKey) }
)
Complete-Job -Checks $checks
