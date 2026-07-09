$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$w = 'C:\ProvTemp'
New-Item -ItemType Directory -Path $w -Force | Out-Null
$raw = 'https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/Update-Windows.ps1'
Invoke-WebRequest -Uri $raw -OutFile "$w\Update-Windows.ps1" -UseBasicParsing
@(
"try {",
"  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
"  Invoke-WebRequest -Uri '$raw' -OutFile '$w\Update-Windows.ps1' -UseBasicParsing -TimeoutSec 120",
"} catch {}",
"& '$w\Update-Windows.ps1'"
) | Set-Content "$w\Resume-Update.ps1" -Encoding UTF8
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$w\Resume-Update.ps1`""
$t = New-ScheduledTaskTrigger -AtStartup
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12)
Register-ScheduledTask -TaskName 'QualitUpdateResume' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
Start-ScheduledTask -TaskName 'QualitUpdateResume'
Write-Output 'Update run started in the background (task: QualitUpdateResume).'
Write-Output 'Progress: desktop file UPDATES RUNNING - STATUS.txt. Done when it becomes UPDATES COMPLETE.txt.'
Write-Output 'The machine will reboot itself as needed and resume automatically.'
