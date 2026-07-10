# =============================================================================
# Qualit provisioning - JOB: rename PC + Admin account
# https://github.com/andrewmcdonald2002/qualit-provision
#
# Datto quick job with INPUT VARIABLES (both optional):
#   PCName        - computer name to assign (e.g. QCC-LT-014)
#   AdminPassword - password for the local Admin account
#
# If either variable is missing (e.g. the job ran automatically from an
# initial-audit sequence), a PROMPT WINDOW opens on the machine's own screen
# for the tech who is prepping it. The job waits up to 30 minutes for the
# answers; if nobody responds (or nobody is logged in) it fails loudly.
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

# --- on-device prompt when values were not supplied by the job -----------------
if ([string]::IsNullOrWhiteSpace($PCName) -or [string]::IsNullOrWhiteSpace($AdminPw)) {
    Write-JobLog 'Variables not supplied - opening a prompt window on the device.'

    $console = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ([string]::IsNullOrWhiteSpace($console)) {
        Write-JobLog 'No one is logged on to the device, so no prompt can be shown.' 'ERROR'
        Send-FailureReport -Detail 'Name/password not supplied and no user logged on to prompt. Log a tech in (or supply job variables) and re-run.'
        exit 1
    }

    $answerFile = 'C:\ProvTemp\bootstrap-answers.json'
    Remove-Item $answerFile -Force -ErrorAction SilentlyContinue

    # The prompt runs in the LOGGED-ON tech's session (SYSTEM cannot show UI).
    $promptScript = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = 'Qualit Provisioning - New PC Setup'
$f.Size = New-Object System.Drawing.Size(430, 260)
$f.StartPosition = 'CenterScreen'
$f.TopMost = $true
$f.FormBorderStyle = 'FixedDialog'
$f.MaximizeBox = $false

$l1 = New-Object System.Windows.Forms.Label
$l1.Text = 'Computer name (per client naming convention):'
$l1.Location = New-Object System.Drawing.Point(15, 20)
$l1.Size = New-Object System.Drawing.Size(390, 20)
$t1 = New-Object System.Windows.Forms.TextBox
$t1.Location = New-Object System.Drawing.Point(15, 42)
$t1.Size = New-Object System.Drawing.Size(385, 25)
$t1.CharacterCasing = 'Upper'

$l2 = New-Object System.Windows.Forms.Label
$l2.Text = 'Local Admin password:'
$l2.Location = New-Object System.Drawing.Point(15, 80)
$l2.Size = New-Object System.Drawing.Size(390, 20)
$t2 = New-Object System.Windows.Forms.TextBox
$t2.Location = New-Object System.Drawing.Point(15, 102)
$t2.Size = New-Object System.Drawing.Size(385, 25)
$t2.UseSystemPasswordChar = $true

$l3 = New-Object System.Windows.Forms.Label
$l3.Text = 'The PC will rename itself and REBOOT after you click OK.'
$l3.Location = New-Object System.Drawing.Point(15, 140)
$l3.Size = New-Object System.Drawing.Size(390, 20)

$ok = New-Object System.Windows.Forms.Button
$ok.Text = 'OK'
$ok.Location = New-Object System.Drawing.Point(310, 175)
$ok.Add_Click({
    if ($t1.Text.Trim() -eq '' -or $t2.Text -eq '') { return }
    if ($t1.Text.Trim() -notmatch '^[A-Za-z0-9-]{1,15}$') {
        [System.Windows.Forms.MessageBox]::Show('Computer name must be 1-15 characters: letters, numbers, hyphens only.') | Out-Null
        return
    }
    @{ pcName = $t1.Text.Trim(); adminPw = $t2.Text } | ConvertTo-Json |
        Set-Content -Path 'C:\ProvTemp\bootstrap-answers.json' -Encoding UTF8
    $f.Close()
})
$f.Controls.AddRange(@($l1,$t1,$l2,$t2,$l3,$ok))
$f.Add_Shown({ $f.Activate(); $t1.Focus() })
[void]$f.ShowDialog()
'@
    $promptPath = 'C:\ProvTemp\Prompt-Provision.ps1'
    $promptScript | Set-Content -Path $promptPath -Encoding UTF8

    # Run the prompt as the logged-on user via a one-shot scheduled task.
    $taskName = 'QualitProvisionPrompt'
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$promptPath`""
    $principal = New-ScheduledTaskPrincipal -UserId $console -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-JobLog "Prompt shown to logged-on user '$console'. Waiting up to 30 minutes for answers."

    $waited = 0
    while ($waited -lt 1800 -and -not (Test-Path $answerFile)) {
        Start-Sleep -Seconds 5
        $waited += 5
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $promptPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $answerFile)) {
        Write-JobLog 'No answers received within 30 minutes.' 'ERROR'
        Send-FailureReport -Detail 'On-device prompt timed out after 30 min with no answers. Re-run the job when a tech is at the machine.'
        exit 1
    }
    $answers = Get-Content $answerFile -Raw | ConvertFrom-Json
    Remove-Item $answerFile -Force -ErrorAction SilentlyContinue   # don't leave the password on disk
    $PCName  = $answers.pcName
    $AdminPw = $answers.adminPw
    Write-JobLog "Answers received. Proceeding with name '$PCName'."
}

if ([string]::IsNullOrWhiteSpace($PCName))  { Write-JobLog 'No computer name available.' 'ERROR';  Send-FailureReport -Detail 'PCName missing after prompt'; exit 1 }
if ([string]::IsNullOrWhiteSpace($AdminPw)) { Write-JobLog 'No Admin password available.' 'ERROR'; Send-FailureReport -Detail 'AdminPassword missing after prompt'; exit 1 }

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
