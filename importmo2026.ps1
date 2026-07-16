<#
.SYNOPSIS
    importmo2026.ps1 -- Hourly wrapper: download the latest MO CSV from
    nro.group and import it into Fuse if (and only if) it is new.

.DESCRIPTION
    1. Note the newest CSV in the download folder (by LastWriteTime)
    2. Run download-nro-csv.ps1 (same folder as this script; it skips the
       SharePoint fetch when the latest file is already on disk)
    3. Note the newest CSV again -- if unchanged, exit quietly (nothing new)
    4. Otherwise run the importer:
         C:\Tools\FuseGtech\GtechConsole importmo2026 <full path to csv>

    Exit codes: 0 = success or nothing new; non-zero = downloader or
    importer failed (Task Scheduler will record it as a failed run).

.PARAMETER DownloadDir
    Folder the CSVs are downloaded to.

.PARAMETER Email
    nro.group login email. Defaults to $env:NRO_EMAIL (passed through to
    the downloader, which also falls back to the env var itself).

.PARAMETER Password
    nro.group login password. Defaults to $env:NRO_PASSWORD.

.PARAMETER Importer
    Path to GtechConsole.

.EXAMPLE
    .\importmo2026.ps1

.EXAMPLE
    # Hourly scheduled task (run as the user that has NRO_* env vars set):
    schtasks /Create /TN "Fuse\ImportMO2026" /SC HOURLY ^
      /TR "cmd /c powershell -NoProfile -ExecutionPolicy Bypass -File C:\fuse\GTECH\importmo2026.ps1 >> C:\fuse\GTECH\importmo2026.log 2>&1"
#>

[CmdletBinding()]
param(
    [string]$DownloadDir = 'C:\fuse\GTECH\NRO\MNLOTTO2026',
    [string]$Email       = $env:NRO_EMAIL,
    [string]$Password    = $env:NRO_PASSWORD,
    [string]$Importer    = 'C:\Tools\FuseGtech\GtechConsole'
)

$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}
function Fail { param([string]$Message)
    Write-Host ("[{0}] x {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -ForegroundColor Red
    exit 1
}

function Get-LatestCsv { param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    Get-ChildItem -Path $Dir -Filter '*.csv' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

# Allow 'GtechConsole' vs 'GtechConsole.exe'
if (-not (Test-Path $Importer) -and (Test-Path "$Importer.exe")) { $Importer = "$Importer.exe" }
if (-not (Test-Path $Importer)) { Fail "Importer not found: $Importer" }

$downloader = Join-Path $PSScriptRoot 'download-nro-csv.ps1'
if (-not (Test-Path $downloader)) { Fail "Downloader not found: $downloader" }

# --- 1. what do we have now? ---------------------------------------------------
$before = Get-LatestCsv $DownloadDir
if ($before) {
    Write-Log "Latest before download: $($before.Name) ($($before.LastWriteTime))"
} else {
    Write-Log "No existing CSVs in $DownloadDir"
}

# --- 2. run the downloader -------------------------------------------------------
Write-Log 'Running downloader ...'
$dlArgs = @($DownloadDir)
if ($Email)    { $dlArgs += @('-Email', $Email) }
if ($Password) { $dlArgs += @('-Password', $Password) }
& $downloader @dlArgs | Out-Null   # discard its stdout (the path); its log lines still show
if ($LASTEXITCODE -ne 0) { Fail "Downloader failed (exit $LASTEXITCODE)" }

# --- 3. anything new? ------------------------------------------------------------
$after = Get-LatestCsv $DownloadDir
if (-not $after) { Fail "No CSV found in $DownloadDir after download" }

$isNew = (-not $before) -or
         ($after.FullName -ne $before.FullName) -or
         ($after.LastWriteTime -ne $before.LastWriteTime)
if (-not $isNew) {
    Write-Log "Nothing new ($($after.Name) unchanged). Exiting."
    exit 0
}

# --- 4. import ---------------------------------------------------------------------
Write-Log "New file detected: $($after.Name)"
Write-Log "Importing: $Importer importmo2026 $($after.FullName)"
& $Importer importmo2026 $after.FullName
if ($LASTEXITCODE -ne 0) { Fail "Importer failed (exit $LASTEXITCODE)" }

Write-Log "Import complete: $($after.Name)"
exit 0
