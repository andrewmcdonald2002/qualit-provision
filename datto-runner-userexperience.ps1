$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$w = 'C:\ProvTemp'
New-Item -ItemType Directory -Path $w -Force | Out-Null
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/andrewmcdonald2002/qualit-provision/main/Set-UserExperience.ps1' -OutFile "$w\Set-UserExperience.ps1" -UseBasicParsing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$w\Set-UserExperience.ps1"
exit $LASTEXITCODE
