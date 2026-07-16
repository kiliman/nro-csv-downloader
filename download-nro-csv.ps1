<#
.SYNOPSIS
    download-nro-csv.ps1 — Log into nro.group (Supabase auth) and download the
    latest CSV for a project from its SharePoint backing store.

.DESCRIPTION
    Flow (reverse-engineered from nro.group.har):
      1. POST Supabase password grant            -> access_token (JWT)
      2. GET  serverFn listProjects (Bearer)     -> [{id, name}, ...]
      3. POST serverFn latestFileMeta (Bearer)   -> {name, size, uploaded_at}  (info only)
      4. POST serverFn getDownloadUrl (Bearer)   -> {url, filename}  (SharePoint, self-authed via tempauth)
      5. GET  SharePoint url                      -> the CSV bytes

    The nro.group server functions authenticate with the Supabase access_token in
    an `Authorization: Bearer` header. The SharePoint URL carries its own short-lived
    `tempauth` token, so the final download needs no extra auth.

.PARAMETER OutputDir
    Download directory. Defaults to $env:OUTPUT_DIR, then .\downloads

.PARAMETER Email
    Login email. Defaults to $env:NRO_EMAIL

.PARAMETER Password
    Login password. Defaults to $env:NRO_PASSWORD

.PARAMETER Project
    Optional project name substring to match; defaults to first project.
    Falls back to $env:NRO_PROJECT

.PARAMETER Force
    Re-download even if the file already exists. Also honors $env:FORCE=1

.EXAMPLE
    $env:NRO_EMAIL = 'you@example.com'
    $env:NRO_PASSWORD = 'secret'
    .\download-nro-csv.ps1 C:\data\downloads
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$OutputDir = $(if ($env:OUTPUT_DIR) { $env:OUTPUT_DIR } else { '.\downloads' }),
    [string]$Email    = $env:NRO_EMAIL,
    [string]$Password = $env:NRO_PASSWORD,
    [string]$Project  = $env:NRO_PROJECT,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # big speedup for Invoke-WebRequest on PS 5.1

# PS 5.1 defaults to old TLS; force TLS 1.2 (no-op on PS 7+)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

if ($env:FORCE -eq '1') { $Force = $true }

# --- config -----------------------------------------------------------------
$SupabaseUrl = 'https://yqbcixrtovuskzimsnpo.supabase.co'
# Public anon key (safe to embed; it's shipped in the site's JS bundle).
$SupabaseAnon = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlxYmNpeHJ0b3Z1c2t6aW1zbnBvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4MTA5NjQsImV4cCI6MjA5NjM4Njk2NH0.pO3lT_X-gcFRAAdX9jr3LZ4-ZG_MM8l_sJnvB6g6Ogo'

$Base           = 'https://nro.group/_serverFn'
$FnListProjects = '59c3792d31a5b9cb9e06bab31c7a172e69f9dda504b572ea2bb1c696d87cbf5d'
$FnLatestFile   = '58b9ea97c3cb8d74d07569fcfd4475ce91f63baf9ebbd499dbf61b03b754f77e'
$FnDownloadUrl  = 'c0bf35af7f5ab83c3154e654edf41fa7ba88bf099fe874041d5ebb1619e10b0a'

function Write-Log { param([string]$Message)
    Write-Host '▸ ' -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}
function Fail { param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
    exit 1
}

if (-not $Email)    { Fail 'Set NRO_EMAIL (or pass -Email)' }
if (-not $Password) { Fail 'Set NRO_PASSWORD (or pass -Password)' }

# Build a TanStack "framed" request body wrapping a single {key:value} string arg.
function New-FramedArg { param([string]$Key, [string]$Value)
    '{"t":{"t":10,"i":0,"p":{"k":["data"],"v":[{"t":10,"i":1,"p":{"k":["' + $Key + '"],"v":[{"t":1,"s":"' + $Value + '"}]},"o":0}]},"o":0},"f":63,"m":[]}'
}

# --- 1. login -----------------------------------------------------------------
Write-Log "Logging in as $Email ..."
$loginBody = @{ email = $Email; password = $Password; gotrue_meta_security = @{} } | ConvertTo-Json -Compress
try {
    $login = Invoke-RestMethod -Method Post -Uri "$SupabaseUrl/auth/v1/token?grant_type=password" `
        -Headers @{ apikey = $SupabaseAnon } `
        -ContentType 'application/json;charset=UTF-8' `
        -Body $loginBody
} catch {
    $detail = $_.ErrorDetails.Message
    if ($detail) {
        try {
            $err = $detail | ConvertFrom-Json
            $detail = if ($err.error_description) { $err.error_description } elseif ($err.msg) { $err.msg } else { $detail }
        } catch {}
    } else { $detail = $_.Exception.Message }
    Fail "Login failed: $detail"
}
$token = $login.access_token
if (-not $token) { Fail "Login failed: $($login | ConvertTo-Json -Compress)" }
Write-Log 'Authenticated.'

function Invoke-AuthGet { param([string]$Fn)
    Invoke-RestMethod -Uri "$Base/$Fn" -Headers @{
        Authorization      = "Bearer $token"
        accept             = 'application/json'
        'x-tsr-serverfn'   = 'true'
    }
}
function Invoke-AuthPost { param([string]$Fn, [string]$Body)
    Invoke-RestMethod -Method Post -Uri "$Base/$Fn" -Headers @{
        Authorization      = "Bearer $token"
        'x-tsr-serverfn'   = 'true'
    } -ContentType 'application/json' -Body $Body
}

# --- 2. pick project ----------------------------------------------------------
Write-Log 'Fetching projects ...'
$projectsResp = Invoke-AuthGet $FnListProjects
# Flatten framed response -> objects with Id/Name. Result is v[0], an array (.a) of {id,name} objects.
$rows = @($projectsResp.p.v[0].a | ForEach-Object {
    [pscustomobject]@{ Id = $_.p.v[0].s; Name = $_.p.v[1].s }
})
if ($rows.Count -eq 0) {
    Fail "No projects returned (token expired or unauthorized?): $($projectsResp | ConvertTo-Json -Compress -Depth 20)"
}

if ($Project) {
    $projectRow = $rows | Where-Object { $_.Name -like "*$Project*" } | Select-Object -First 1
    if (-not $projectRow) {
        Fail "No project matched '$Project'. Available: $(($rows.Name) -join '; ')"
    }
} else {
    $projectRow = $rows[0]
}
$projectId   = $projectRow.Id
$projectName = $projectRow.Name
Write-Log "Project: $projectName ($projectId)"

# --- 3. latest file metadata ---------------------------------------------------
# We learn the filename here (it's in the payload) so we can skip the expensive
# SharePoint fetch entirely when we already have this exact file on disk.
$meta = Invoke-AuthPost $FnLatestFile (New-FramedArg 'projectId' $projectId)
$metaName = $meta.p.v[0].p.v[0].s; if (-not $metaName) { $metaName = '?' }
$metaDate = $meta.p.v[0].p.v[2].s; if (-not $metaDate) { $metaDate = '?' }
Write-Log "Latest file: $metaName (uploaded $metaDate)"

$existing = Join-Path $OutputDir $metaName
if (-not $Force -and (Test-Path $existing) -and (Get-Item $existing).Length -gt 0) {
    Write-Log "Already have $metaName — skipping SharePoint download. (use -Force to re-download)"
    Write-Output $existing
    exit 0
}

# --- 4. get SharePoint download URL ---------------------------------------------
$dlResp = Invoke-AuthPost $FnDownloadUrl (New-FramedArg 'projectId' $projectId)
$url      = $dlResp.p.v[0].p.v[0].s
$filename = $dlResp.p.v[0].p.v[1].s
if (-not $url) { Fail "No download URL returned: $($dlResp | ConvertTo-Json -Compress -Depth 20)" }
if (-not $filename) { $filename = $metaName }

# --- 5. download ----------------------------------------------------------------
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$out = Join-Path $OutputDir $filename
Write-Log "Downloading -> $out"
try {
    Invoke-WebRequest -Uri $url -OutFile $out   # follows redirects by default
} catch {
    Fail "Download failed: $($_.Exception.Message)"
}

$size = (Get-Item $out).Length
Write-Log "Done: $out ($size bytes)"
Write-Output $out
