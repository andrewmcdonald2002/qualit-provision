# =============================================================================
# Qualit provisioning - shared helpers (dot-sourced by every job script)
# https://github.com/andrewmcdonald2002/qualit-provision
# =============================================================================

$ReportUrl = 'https://provision.qualit.com/api/report'
$WorkDir   = 'C:\ProvTemp'
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

function Write-JobLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    try { Add-Content -Path (Join-Path $WorkDir "$script:JobName.log") -Value $line -ErrorAction SilentlyContinue } catch {}
}

# POST a failure to provision.qualit.com so it can alert + open a GitHub issue
# for diagnosis. Fire-and-forget: reporting must never crash the job itself.
function Send-FailureReport {
    param([string]$Detail)
    try {
        $logPath = Join-Path $WorkDir "$script:JobName.log"
        $tail = ''
        if (Test-Path $logPath) { $tail = (Get-Content $logPath -Tail 60) -join "`n" }
        $body = @{
            job      = $script:JobName
            computer = $env:COMPUTERNAME
            detail   = $Detail
            log      = $tail
            os       = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
            timeUtc  = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri $ReportUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
        Write-JobLog 'Failure report sent to provision.qualit.com.'
    } catch {
        Write-JobLog "Could not send failure report: $($_.Exception.Message)" 'WARN'
    }
}

# Verify a list of named checks. Each check is @{ name='...'; ok=$true/$false }.
# Logs each result; if any failed, sends ONE report and exits 1 so Datto flags
# the job as FAILED.
function Complete-Job {
    param([array]$Checks)
    $failed = @($Checks | Where-Object { -not $_.ok })
    foreach ($c in $Checks) {
        $mark = if ($c.ok) { 'PASS' } else { 'FAIL' }
        Write-JobLog ("VERIFY {0}: {1}" -f $mark, $c.name)
    }
    if ($failed.Count -gt 0) {
        $names = ($failed | ForEach-Object { $_.name }) -join '; '
        Write-JobLog "JOB FAILED verification: $names" 'ERROR'
        Send-FailureReport -Detail "Verification failed: $names"
        exit 1
    }
    Write-JobLog 'JOB OK - all verifications passed.'
    exit 0
}
