# nro.group CSV downloader

A small Bash script that logs into [nro.group](https://nro.group) and downloads the
latest CSV export for a project. The site is a TanStack Start app backed by
**Supabase** auth and a **SharePoint** file store; this script replicates the
browser's network flow so you can pull the file headlessly.

## How it works

```
1. POST  Supabase password grant            -> access_token (JWT)
2. GET   nro.group /_serverFn listProjects  -> [{id, name}, ...]   (Bearer auth)
3. POST  nro.group /_serverFn latestFile     -> {name, uploaded_at} (Bearer auth)
4. POST  nro.group /_serverFn getDownloadUrl -> {url, filename}     (Bearer auth)
5. GET   SharePoint download.aspx?...tempauth=...  -> the CSV bytes
```

- The `nro.group` server functions authenticate with the Supabase `access_token`
  in an `Authorization: Bearer` header (no cookies involved).
- The SharePoint URL carries its own short-lived `tempauth` token, so the final
  download needs no extra auth. Because that token expires in ~1 hour, the script
  re-fetches the URL (step 4) on every run rather than caching it.
- After step 3 the filename is known, so if you already have that exact file on
  disk the script **skips the SharePoint download entirely**.

## Requirements

- `bash`, `curl`, `jq` (all standard on macOS / Linux)

## Setup

```bash
cp .env.example .env      # then edit .env with your real credentials
```

`.env`:

```bash
NRO_EMAIL=you@example.com
NRO_PASSWORD=your-password
```

## Usage

```bash
set -a; source .env; set +a      # load credentials into the environment
./download-nro-csv.sh            # downloads to ./downloads/
```

Or pass everything inline:

```bash
NRO_EMAIL=… NRO_PASSWORD=… ./download-nro-csv.sh /path/to/output
```

The script prints the saved file path to stdout, so it composes in pipelines.

### Environment variables

| Variable       | Required | Default       | Description |
|----------------|----------|---------------|-------------|
| `NRO_EMAIL`    | yes      | —             | Login email |
| `NRO_PASSWORD` | yes      | —             | Login password |
| `NRO_PROJECT`  | no       | first project | Match a project by name substring (e.g. `"Quarterly"`) |
| `OUTPUT_DIR`   | no       | `./downloads` | Download directory (can also be passed as `$1`) |
| `FORCE`        | no       | unset         | Set to `1` to re-download even if the file already exists |

## Automating it

The script no-ops when the latest file is already present, so it's safe to run on
a schedule (cron, a launchd job, etc.) — it only transfers bytes when a fresh CSV
has been uploaded.

## Security notes

- **Credentials never live in the repo** — they come from environment variables.
  `.env`, `*.har`, and `downloads/` are git-ignored.
- The Supabase **anon key** embedded in the script is the public anonymous key
  (shipped in the site's own JS bundle); it grants nothing on its own — access is
  gated by Supabase Row Level Security and a valid user login.
