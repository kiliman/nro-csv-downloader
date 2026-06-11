#!/usr/bin/env bash
#
# download-nro-csv.sh — Log into nro.group (Supabase auth) and download the
# latest CSV for a project from its SharePoint backing store.
#
# Flow (reverse-engineered from nro.group.har):
#   1. POST Supabase password grant            -> access_token (JWT)
#   2. GET  serverFn listProjects (Bearer)     -> [{id, name}, ...]
#   3. POST serverFn latestFileMeta (Bearer)   -> {name, size, uploaded_at}  (info only)
#   4. POST serverFn getDownloadUrl (Bearer)   -> {url, filename}  (SharePoint, self-authed via tempauth)
#   5. GET  SharePoint url                      -> the CSV bytes
#
# The nro.group server functions authenticate with the Supabase access_token in
# an `Authorization: Bearer` header. The SharePoint URL carries its own short-lived
# `tempauth` token, so the final download needs no extra auth.
#
# Usage:
#   NRO_EMAIL=you@example.com NRO_PASSWORD=secret ./download-nro-csv.sh [OUTPUT_DIR]
#
# Env vars:
#   NRO_EMAIL      (required) login email
#   NRO_PASSWORD   (required) login password
#   NRO_PROJECT    (optional) project name substring to match; defaults to first project
#   OUTPUT_DIR     (optional) download dir; also positional $1; defaults to ./downloads
#   FORCE          (optional) set to 1 to re-download even if the file already exists
#
set -euo pipefail

# --- config -----------------------------------------------------------------
SUPABASE_URL="https://yqbcixrtovuskzimsnpo.supabase.co"
# Public anon key (safe to embed; it's shipped in the site's JS bundle).
SUPABASE_ANON="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlxYmNpeHJ0b3Z1c2t6aW1zbnBvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4MTA5NjQsImV4cCI6MjA5NjM4Njk2NH0.pO3lT_X-gcFRAAdX9jr3LZ4-ZG_MM8l_sJnvB6g6Ogo"

BASE="https://nro.group/_serverFn"
FN_LIST_PROJECTS="59c3792d31a5b9cb9e06bab31c7a172e69f9dda504b572ea2bb1c696d87cbf5d"
FN_LATEST_FILE="58b9ea97c3cb8d74d07569fcfd4475ce91f63baf9ebbd499dbf61b03b754f77e"
FN_DOWNLOAD_URL="c0bf35af7f5ab83c3154e654edf41fa7ba88bf099fe874041d5ebb1619e10b0a"

OUTPUT_DIR="${1:-${OUTPUT_DIR:-./downloads}}"
NRO_EMAIL="${NRO_EMAIL:?Set NRO_EMAIL}"
NRO_PASSWORD="${NRO_PASSWORD:?Set NRO_PASSWORD}"
NRO_PROJECT="${NRO_PROJECT:-}"

log() { printf '\033[36m▸\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Build a TanStack "framed" request body wrapping a single {key:value} string arg.
# $1=key  $2=value
framed_arg() {
  printf '{"t":{"t":10,"i":0,"p":{"k":["data"],"v":[{"t":10,"i":1,"p":{"k":["%s"],"v":[{"t":1,"s":"%s"}]},"o":0}]},"o":0},"f":63,"m":[]}' "$1" "$2"
}

# --- 1. login ---------------------------------------------------------------
log "Logging in as $NRO_EMAIL ..."
LOGIN=$(curl -sS -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_ANON" \
  -H "content-type: application/json;charset=UTF-8" \
  -d "$(printf '{"email":"%s","password":"%s","gotrue_meta_security":{}}' "$NRO_EMAIL" "$NRO_PASSWORD")")
TOKEN=$(echo "$LOGIN" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || die "Login failed: $(echo "$LOGIN" | jq -r '.error_description // .msg // .' 2>/dev/null || echo "$LOGIN")"
log "Authenticated."

auth_get()  { curl -sS "$BASE/$1" -H "Authorization: Bearer $TOKEN" -H "accept: application/json" -H "x-tsr-serverfn: true"; }
auth_post() { curl -sS -X POST "$BASE/$1" -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" -H "x-tsr-serverfn: true" -d "$2"; }

# --- 2. pick project --------------------------------------------------------
log "Fetching projects ..."
PROJECTS=$(auth_get "$FN_LIST_PROJECTS")
# Flatten framed response -> "id<TAB>name" lines. result is v[0], an array (.a) of {id,name} objects.
mapfile -t ROWS < <(echo "$PROJECTS" | jq -r '.p.v[0].a[]? | "\(.p.v[0].s)\t\(.p.v[1].s)"')
[ "${#ROWS[@]}" -gt 0 ] || die "No projects returned (token expired or unauthorized?): $PROJECTS"

PROJECT_ROW=""
if [ -n "$NRO_PROJECT" ]; then
  for r in "${ROWS[@]}"; do [[ "${r#*$'\t'}" == *"$NRO_PROJECT"* ]] && PROJECT_ROW="$r" && break; done
  [ -n "$PROJECT_ROW" ] || die "No project matched '$NRO_PROJECT'. Available: $(printf '%s; ' "${ROWS[@]#*$'\t'}")"
else
  PROJECT_ROW="${ROWS[0]}"
fi
PROJECT_ID="${PROJECT_ROW%%$'\t'*}"
PROJECT_NAME="${PROJECT_ROW#*$'\t'}"
log "Project: $PROJECT_NAME ($PROJECT_ID)"

# --- 3. latest file metadata ------------------------------------------------
# We learn the filename here (it's in the payload) so we can skip the expensive
# SharePoint fetch entirely when we already have this exact file on disk.
META=$(auth_post "$FN_LATEST_FILE" "$(framed_arg projectId "$PROJECT_ID")")
META_NAME=$(echo "$META" | jq -r '.p.v[0].p.v[0].s // "?"')
META_DATE=$(echo "$META" | jq -r '.p.v[0].p.v[2].s // "?"')
log "Latest file: $META_NAME (uploaded $META_DATE)"

EXISTING="$OUTPUT_DIR/$META_NAME"
if [ -z "${FORCE:-}" ] && [ -s "$EXISTING" ]; then
  log "Already have $META_NAME — skipping SharePoint download. (set FORCE=1 to re-download)"
  echo "$EXISTING"
  exit 0
fi

# --- 4. get SharePoint download URL -----------------------------------------
DLRESP=$(auth_post "$FN_DOWNLOAD_URL" "$(framed_arg projectId "$PROJECT_ID")")
URL=$(echo "$DLRESP" | jq -r '.p.v[0].p.v[0].s // empty')
FILENAME=$(echo "$DLRESP" | jq -r '.p.v[0].p.v[1].s // empty')
[ -n "$URL" ] || die "No download URL returned: $DLRESP"
[ -n "$FILENAME" ] || FILENAME="$META_NAME"

# --- 5. download ------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/$FILENAME"
log "Downloading -> $OUT"
HTTP=$(curl -sS -L "$URL" -o "$OUT" -w "%{http_code}")
[ "$HTTP" = "200" ] || die "Download failed (HTTP $HTTP)"

SIZE=$(wc -c < "$OUT" | tr -d ' ')
log "Done: $OUT ($SIZE bytes)"
echo "$OUT"
