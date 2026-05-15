# GCP Cloud Logging → TimeSketch tools

Two Python scripts for getting Google Cloud Platform audit / Cloud
Logging exports into TimeSketch as JSONL timelines. Both live under
`scripts/` in this repo; both are operational tools meant to be run
from an analyst / engineer workstation, not from inside the pipeline
container.

| Script | When to use |
|---|---|
| [`gcp_convert_to_ts.py`](gcp_convert_to_ts.py) | You already have a `gcloud logging read --format=json` output file (possibly truncated by mid-export auth death — see "Why this exists" below) and just need it reshaped into TS-uploadable JSONL. No `gcloud` required to run. |
| [`gcp_export_to_ts.py`](gcp_export_to_ts.py) | You have GCP access and want to do the export safely from scratch. Walks a date range in time windows, separates stderr, recovers from auth expiry without losing previous days. |

Both scripts produce one JSONL line per GCP log event, with three
TS-shaped fields injected: `datetime` (copied from event `timestamp`),
synthesised `message`, and `timestamp_desc`. The original GCP event is
preserved verbatim alongside.

## Install

Both scripts need `ijson` for streaming JSON parsing:

```bash
pip install ijson
```

Tested on Python 3.11+.

## Why this exists

Caught on a case-1336 monthly export in May 2026. The original
`gcloud logging read 'timestamp>="..."' --format=json > 2025-11.json`
command had three pathologies stacked together:

1. **Multi-hour export.** A full month of audit logs from a busy
   project took longer than `gcloud`'s default OAuth access-token
   lifetime (~1 hour).
2. **stderr captured into the JSON file.** The shell redirect pulled
   both stdout and stderr into the same file. When the token expired
   mid-stream, `gcloud` wrote a multi-line
   `ERROR: (gcloud.logging.read) Reauthentication failed` message to
   stderr, and that text landed inside the JSON byte stream.
3. **Descending order (default).** `gcloud logging read` defaults to
   `--order=desc` (newest first). Combined with the mid-export death,
   that meant the salvaged events covered roughly the *last 2-3 hours
   of the requested range*, not the start — analyst expected a full
   month, got an evening.

`gcp_convert_to_ts.py` recovers as much as possible from existing
broken exports. `gcp_export_to_ts.py` prevents the broken export
shape from happening again.

---

## `gcp_convert_to_ts.py` — convert existing JSON files

Stream-parses a `gcloud logging read --format=json` output file via
`ijson` and writes TS-uploadable JSONL.

```bash
python scripts/gcp_convert_to_ts.py <input.json> <output.jsonl>
```

Behaviour:

* Reports a progress line every 100,000 events on stderr so you can
  watch it work.
* Per-event errors (rare malformed records) are counted and skipped,
  not fatal.
* A stream-level parse error (the auth-death corruption) halts the
  stream. **Every event written before that point IS in the output
  file** -- partial output is real output, uploadable as-is.

After the run, validate the JSONL before uploading:

```bash
# Event count
wc -l output.jsonl

# Earliest / latest event time
head -1 output.jsonl | python3 -c "import sys,json; print('FIRST:', json.loads(sys.stdin.read())['datetime'])"
tail -1 output.jsonl | python3 -c "import sys,json; print('LAST: ', json.loads(sys.stdin.read())['datetime'])"
```

**If FIRST > LAST** the source was descending-order and what you have
is the most recent slice of the requested range, not the start of it.
See "Why this exists" above.

### TimeSketch upload

Drag the `.jsonl` straight into the case sketch -> Add Timeline -> name
clearly (e.g. `GCP audit - 2025-11 (partial)`). For files > ~2 GB
split first to avoid HTTP upload limits and to parallelise indexing:

```bash
split -l 250000 output.jsonl output_part_
```

Each `output_part_*` becomes its own timeline.

---

## `gcp_export_to_ts.py` — full windowed re-export

The right tool when you have GCP access and want to do the export
properly. Walks the requested date range in `--window` increments
(default 1d) so each `gcloud` call stays well under the OAuth token
lifetime.

```bash
# 1. Make sure gcloud has a fresh token
gcloud auth login   # or: gcloud auth activate-service-account --key-file=<sa.json>

# 2. Run the windowed exporter
python scripts/gcp_export_to_ts.py \
    --project   <YOUR_PROJECT_ID> \
    --start     2025-11-01 \
    --end       2025-12-01 \
    --window    1d \
    --filter    'logName=~"cloudaudit"' \
    --output    2025-11.jsonl \
    --work-dir  ./gcp_2025-11_work
```

What it does on every iteration:

* Constructs the per-window `gcloud logging read` filter by ANDing the
  user's `--filter` with `timestamp>="<window_start>" AND timestamp<"<window_end>"`.
* Runs `gcloud` with **stderr redirected to a separate file** (the
  cause of the original case-1336 corruption is impossible by design).
* Forces `--order=asc` (oldest first) so a future token death loses
  the *end* of the range rather than the start.
* Validates the window's output before keeping it:
  * non-zero gcloud exit code -> abort, leave state for resume
  * stdout not a closed JSON array (`[` … `]`) -> abort (truncated)
  * stderr contains `ERROR:` line -> abort (auth fail mid-stream)
* Streams the validated JSON through `ijson` to TS-shaped JSONL.
* Drops a `.done` marker only after the window is fully validated +
  converted.
* Concatenates all completed window JSONLs into the final `--output`.

### Resume after auth death

The script does NOT prompt for auth -- if a token expires mid-run, it
aborts cleanly with a message. Refresh and re-run **the exact same
command**:

```bash
gcloud auth login
python scripts/gcp_export_to_ts.py ...  # exact same args
```

Completed windows are skipped (the `.done` marker). Only the failing
window forward is re-attempted.

### Picking the right window size

| Window | Wall time per call | Use when |
|---|---|---|
| `1d` (default) | minutes to ~30min depending on volume | Default. Token-safe for most projects. |
| `6h` | seconds to a few minutes | Very high volume projects (10M+ events/day). |
| `1h` | seconds | Cap-edge cases or interactive debugging. |

A smaller window means more `gcloud` calls but a smaller blast radius
per failure.

### Auth options

* Interactive: `gcloud auth login` -- access tokens ~1h, refresh token
  long-lived, requires browser. Script aborts cleanly on token
  expiry; you re-login + re-run.
* Service account: `gcloud auth activate-service-account
  --key-file=<sa.json>` -- no interactive prompt, no token-expiry
  hassle. Best for long unattended runs.

### Output validation

After the export completes, same checks as `gcp_convert_to_ts.py`:

```bash
wc -l 2025-11.jsonl
head -1 2025-11.jsonl | python3 -c "import sys,json; print('FIRST:', json.loads(sys.stdin.read())['datetime'])"
tail -1 2025-11.jsonl | python3 -c "import sys,json; print('LAST: ', json.loads(sys.stdin.read())['datetime'])"
```

With `--order=asc` (forced by the script), FIRST should match your
`--start` and LAST should approach your `--end`. If LAST is much
earlier than `--end`, an intermediate window failed -- look in
`--work-dir` for the failing window's `.err` file.

---

## TS-shaped JSONL — what each event looks like

Both scripts emit JSONL with three TS-required additions on top of
the verbatim GCP event:

```json
{
  "datetime": "2025-11-15T14:23:11.123Z",
  "message": "google.iam.admin.v1.CreateServiceAccount by user@org.com on prod-project",
  "timestamp_desc": "GCP log entry",
  "...": "the original GCP event fields preserved verbatim"
}
```

The synthesised `message` covers the three common GCP log shapes:

* **protoPayload** (audit logs) -> `"<methodName> by <principalEmail> on <project_id>"`
* **jsonPayload** (custom app logs) -> `"<event_subtype|eventName> by <actor> on <project_id>"`
* **textPayload** (raw text) -> `"<severity> - <first 200 chars of textPayload>"`

Falls back to `severity` / `gcp` placeholders when those fields are
absent so no event lands with a blank message.

The original event fields (`protoPayload`, `resource`, `severity`,
`insertId`, `receiveTimestamp`, etc.) are preserved verbatim alongside
the three additions. Analyst queries pivot on the native GCP field
names:

```
protoPayload.authenticationInfo.principalEmail:"redacted@org.com"
protoPayload.methodName:"google.iam.admin.v1.CreateServiceAccount"
resource.labels.project_id:"prod"
severity:"ERROR"
```

## Limitations

* Both scripts assume the source JSON is a top-level JSON **array** of
  events (the default shape from `gcloud logging read --format=json`).
  NDJSON / line-delimited input isn't supported -- if a future
  upstream tool emits that, a separate converter would be a half-page
  of code.
* No retry on transient `gcloud` errors -- the script aborts and
  resumes on re-run instead. Predictable; fits the "leave state for
  the operator" pattern.
* No automatic split for very large output files. If your `--output`
  is > 2 GB and you want it chunked for parallel TS upload, use
  `split -l <events_per_chunk>` after the export completes.

## See also

* TS Web UI upload path: drag JSONL into sketch -> Add timeline ->
  name. Per-timeline indexing runs server-side -- check timeline
  status in the UI for `ready`.
* If a case container hits OpenSearch heap pressure during the
  indexing, see the `OPENRELIK_WORKER_BITS_VERSION`-adjacent block in
  `install.sh` for the per-case heap config pattern.
