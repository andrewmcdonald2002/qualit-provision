# =============================================================================
# Qualit provisioning - JOB: User account + taskbar + default apps
# https://github.com/andrewmcdonald2002/qualit-provision
#
# Run AFTER Chrome / Adobe Acrobat / Office / Zoom are installed (pins and
# default-app bindings need the apps present).
#
# Does:
#   1. Creates the standard local 'User' account (no password).
#   2. Writes the taskbar layout into the Default profile:
#      M365 Copilot, File Explorer, Chrome, Outlook, Word, Excel, Zoom
#      (Store + Edge removed; missing apps are skipped automatically).
#   3. Sets default apps machine-wide: Chrome = browser, Acrobat = PDF.
#
# Taskbar + defaults apply when a NEW profile signs in (that's how 'User'
# gets them on first login). Verifies its own work; exits 1 + reports to
# provision.qualit.com on failure.
# =============================================================================

$ErrorActionPreference = 'Stop'
$script:JobName = 'user-experience'

$common = 'C:\ProvTemp\Common.ps1'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/lib/Common.ps1' -OutFile $common -UseBasicParsing -TimeoutSec 60
} catch {}
. $common

# --- 1. standard User account ---------------------------------------------------
try {
    if (-not (Get-LocalUser -Name 'User' -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name 'User' -NoPassword | Out-Null
        Set-LocalUser -Name 'User' -PasswordNeverExpires $true
        Write-JobLog 'User: account created (no password).'
    } else {
        Write-JobLog 'User: account already exists.'
    }
    if (-not (Get-LocalGroupMember -Group 'Users' -Member 'User' -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group 'Users' -Member 'User' -ErrorAction SilentlyContinue
    }
} catch {
    Write-JobLog "User account step failed: $($_.Exception.Message)" 'ERROR'
}

# --- 1b. suppress Windows "finish setting up your PC" nag (SCOOBE) ----------------
# Applies to NEW profiles by writing into the Default user hive, and to any
# already-created local profiles by walking their loaded/loadable hives.
try {
    reg load 'HKU\QccDefault' 'C:\Users\Default\NTUSER.DAT' | Out-Null
    reg add 'HKU\QccDefault\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' /v ScoobeSystemSettingEnabled /t REG_DWORD /d 0 /f | Out-Null
    [gc]::Collect()
    reg unload 'HKU\QccDefault' | Out-Null
    Write-JobLog 'SCOOBE (finish-setting-up nag) disabled for new profiles.'
} catch {
    Write-JobLog "SCOOBE default-profile step failed: $($_.Exception.Message)" 'WARN'
}
try {
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'S-1-5-21-' -and $_.Name -notmatch '_Classes$' } |
        ForEach-Object {
            reg add "$($_.Name)\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" /v ScoobeSystemSettingEnabled /t REG_DWORD /d 0 /f | Out-Null
        }
    Write-JobLog 'SCOOBE disabled for currently loaded user profiles.'
} catch {
    Write-JobLog "SCOOBE loaded-profiles step failed: $($_.Exception.Message)" 'WARN'
}

# --- 2. taskbar layout (Default profile) -----------------------------------------
$layout = @'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:UWA AppUserModelID="Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe!Microsoft.MicrosoftOfficeHub" />
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ProgramData%\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ProgramData%\Microsoft\Windows\Start Menu\Programs\Outlook.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ProgramData%\Microsoft\Windows\Start Menu\Programs\Word.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ProgramData%\Microsoft\Windows\Start Menu\Programs\Excel.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ProgramData%\Microsoft\Windows\Start Menu\Programs\Zoom\Zoom Workplace.lnk" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@
$shellDir   = "$env:SystemDrive\Users\Default\AppData\Local\Microsoft\Windows\Shell"
$layoutPath = Join-Path $shellDir 'LayoutModification.xml'
try {
    New-Item -ItemType Directory -Path $shellDir -Force | Out-Null
    $layout | Set-Content -Path $layoutPath -Encoding UTF8
    Write-JobLog 'Taskbar layout written to the Default profile.'
} catch {
    Write-JobLog "Taskbar layout step failed: $($_.Exception.Message)" 'ERROR'
}

# --- 3. default apps: Chrome browser, Acrobat PDF ---------------------------------
$assocPath = "$env:ProgramData\DefaultAppAssociations.xml"
$assocXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier="http"   ProgId="ChromeHTML"          ApplicationName="Google Chrome" />
  <Association Identifier="https"  ProgId="ChromeHTML"          ApplicationName="Google Chrome" />
  <Association Identifier=".htm"   ProgId="ChromeHTML"          ApplicationName="Google Chrome" />
  <Association Identifier=".html"  ProgId="ChromeHTML"          ApplicationName="Google Chrome" />
  <Association Identifier=".pdf"   ProgId="Acrobat.Document.DC" ApplicationName="Adobe Acrobat" />
</DefaultAssociations>
"@
try {
    $assocXml | Set-Content -Path $assocPath -Encoding UTF8
    $polKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    New-Item -Path $polKey -Force | Out-Null
    Set-ItemProperty -Path $polKey -Name 'DefaultAssociationsConfiguration' -Value $assocPath -Type String
    try { Dism.exe /Online /Import-DefaultAppAssociations:"$assocPath" | Out-Null } catch {}
    Write-JobLog 'Default apps policy set (Chrome browser, Acrobat PDF).'
} catch {
    Write-JobLog "Default apps step failed: $($_.Exception.Message)" 'ERROR'
}

# --- verify -------------------------------------------------------------------------
$layoutOk = $false
try { if (Test-Path $layoutPath) { [xml](Get-Content $layoutPath -Raw) | Out-Null; $layoutOk = $true } } catch {}
$polVal = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -ErrorAction SilentlyContinue).DefaultAssociationsConfiguration

$checks = @(
    @{ name = 'User account exists';                    ok = [bool](Get-LocalUser -Name 'User' -ErrorAction SilentlyContinue) },
    @{ name = 'Taskbar layout file written + valid XML'; ok = $layoutOk },
    @{ name = 'Default-apps policy points at assoc file'; ok = ($polVal -eq $assocPath) },
    @{ name = 'Assoc file exists';                       ok = (Test-Path $assocPath) }
)
Complete-Job -Checks $checks
