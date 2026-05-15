#!/usr/bin/env python3
"""
gcp_export_to_ts.py -- robust GCP Cloud Logging export to
TimeSketch-ready JSONL.

What it does
============
* Walks [--start, --end) in --window-sized increments (default 1 day).
* For each window, runs `gcloud logging read` with stderr redirected
  to its own file -- this prevents the auth-token-expired failure
  mode where gcloud writes `ERROR: Reauthentication failed` into the
  same stream as the JSON output (the exact problem that ate
  case-1336's 2025-11.json at line 49,728,834).
* Validates each window's output before keeping it:
    * non-zero gcloud exit code  -> abort, leave state for resume
    * stdout not a closed JSON array (`[` ... `]`)  -> abort
    * stderr contains `ERROR:`  -> abort
* Streams the validated JSON through ijson and emits TS-shaped JSONL
  with three added fields per event:
    `datetime`        copied from `event.timestamp` (TS sorts on this)
    `message`         synthesised "<method> by <actor> on <project>"
    `timestamp_desc`  analyst-facing column label
  The original event is preserved verbatim; the three additions sit
  alongside.
* Concatenates the per-window JSONL files into one final output.
* Resumable. The --work-dir holds the raw + per-window JSONL. A
  `.done` marker is dropped only after a window is fully validated +
  converted; re-running with the same args skips done windows.

Auth
====
Run in a shell that already has a working `gcloud auth login` or
`gcloud auth activate-service-account`. This script does NOT prompt
for auth -- if a token expires mid-run, it aborts cleanly with a
clear message; refresh and re-run to pick up from the last
completed window.

Usage
=====
  python gcp_export_to_ts.py \\
      --project my-project-id \\
      --start 2025-11-01 \\
      --end   2025-12-01 \\
      --filter 'resource.type="gce_instance"' \\
      --window 1d \\
      --output gcp_2025-11.jsonl \\
      --work-dir ./gcp_export_work

Dependencies
============
  pip install ijson
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys

try:
    import ijson
except ImportError:
    sys.stderr.write("ijson not found. Install with: pip install ijson\n")
    sys.exit(2)


_WINDOW_RE = re.compile(r"^(?P<n>\d+)(?P<u>[hdHD])$")


def parse_window(spec):
    """`1d`, `6h` -> datetime.timedelta. Anything else raises."""
    m = _WINDOW_RE.match(spec)
    if not m:
        raise argparse.ArgumentTypeError(
            f"invalid --window {spec!r}; expected N + 'h' or 'd' (e.g. 1d, 6h)"
        )
    n = int(m.group("n"))
    u = m.group("u").lower()
    return datetime.timedelta(hours=n) if u == "h" else datetime.timedelta(days=n)


def parse_date(spec):
    """`YYYY-MM-DD` -> UTC datetime at 00:00:00."""
    try:
        return datetime.datetime.strptime(spec, "%Y-%m-%d").replace(
            tzinfo=datetime.timezone.utc
        )
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"invalid date {spec!r}; expected YYYY-MM-DD"
        )


def iso(dt):
    """RFC 3339 with Z suffix; matches what gcloud logging filter expects."""
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def windows(start, end, step):
    """Yield (a, b) covering [start, end) in step-sized chunks. Final
    chunk is clipped to `end` so the last window doesn't over-shoot."""
    cur = start
    while cur < end:
        yield cur, min(cur + step, end)
        cur += step


def run_gcloud(project, gcp_filter, win_start, win_end, raw_path, err_path):
    """Run `gcloud logging read` for one window. Returns (ok, reason).

    Failure modes deliberately caught:
      * non-zero exit (network, auth-fail surfacing in rc)
      * truncated stdout (stream cut mid-export)
      * `ERROR:` in stderr (auth refresh failed mid-stream; same
        contamination that bit case-1336 last week)
    """
    parts = [f'timestamp>="{iso(win_start)}"', f'timestamp<"{iso(win_end)}"']
    if gcp_filter:
        parts.append(f"({gcp_filter})")
    full_filter = " AND ".join(parts)

    cmd = [
        "gcloud", "logging", "read", full_filter,
        "--project", project,
        "--format=json",
        "--order=asc",
    ]

    with open(raw_path, "wb") as out_fh, open(err_path, "wb") as err_fh:
        proc = subprocess.run(cmd, stdout=out_fh, stderr=err_fh, check=False)

    if proc.returncode != 0:
        return False, f"gcloud rc={proc.returncode}; see {err_path}"

    size = os.path.getsize(raw_path)
    if size == 0:
        # gcloud should always write at least `[]` even for empty
        # results -- truly empty stdout means the redirect failed or
        # the process died very early.
        return False, "gcloud produced empty stdout; see err file"

    # First / last byte sanity. Closed JSON array starts with `[` and
    # ends with `]`. Pretty-printed arrays have whitespace before `]`
    # so we strip trailing whitespace before the check.
    with open(raw_path, "rb") as fh:
        first = fh.read(1)
        # Walk backward past trailing whitespace to find the last
        # meaningful byte. 256 bytes of whitespace is more than enough
        # for any sane formatter.
        try:
            fh.seek(-min(256, size), os.SEEK_END)
            tail = fh.read()
        except OSError:
            tail = b""
    last_nonws = tail.rstrip()[-1:] if tail else b""
    if first != b"[" or last_nonws != b"]":
        return False, (
            f"raw output not a closed JSON array (starts {first!r}, "
            f"ends {last_nonws!r}); likely truncated. Check {err_path}."
        )

    if os.path.getsize(err_path) > 0:
        with open(err_path, "rb") as fh:
            err_bytes = fh.read()
        # `WARNING:` lines from gcloud (token-refresh notifications,
        # quota warnings) are noise. Only `ERROR:` is a real abort.
        if b"ERROR:" in err_bytes:
            return False, f"gcloud stderr contains ERROR: line; see {err_path}"

    return True, "ok"


def synthesise_event(ev):
    """Add `datetime` / `message` / `timestamp_desc` to a GCP log
    event in place. Synthesised message handles the three common
    GCP log shapes (protoPayload audit, jsonPayload custom, raw
    textPayload) gracefully -- falls back to severity / 'gcp' if
    none of the structured fields are present."""
    pp = ev.get("protoPayload") or {}
    jp = ev.get("jsonPayload") or {}
    tp = ev.get("textPayload")
    res_labels = (ev.get("resource") or {}).get("labels") or {}

    method = (
        pp.get("methodName")
        or jp.get("event_subtype")
        or jp.get("eventName")
        or ev.get("severity")
        or "gcp"
    )
    actor = (
        (pp.get("authenticationInfo") or {}).get("principalEmail")
        or jp.get("actor")
        or "unknown"
    )
    project = res_labels.get("project_id") or "unknown"

    if tp:
        # textPayload events lack method/actor structure; surface a
        # truncated copy of the text so the analyst sees something
        # useful in the column without bloating event size.
        snippet = tp.replace("\n", " ")[:200]
        msg = f"{ev.get('severity', 'gcp')} - {snippet}"
    else:
        msg = f"{method} by {actor} on {project}"

    ev["datetime"] = ev.get("timestamp")
    ev["message"] = msg
    ev["timestamp_desc"] = "GCP log entry"
    return ev


def convert_window(raw_path, jsonl_path):
    """Stream raw_path through ijson, write TS-shaped JSONL to
    jsonl_path. Returns (events_ok, events_bad, stream_err).

    Per-event errors are caught and counted -- a single weird record
    doesn't kill the whole window. Stream-level errors (mid-array
    truncation) end the stream; we keep what we wrote and report it.
    """
    events_ok = 0
    events_bad = 0
    stream_err = None
    with open(raw_path, "rb") as fin, open(jsonl_path, "w", encoding="utf-8") as fout:
        try:
            for ev in ijson.items(fin, "item"):
                try:
                    synthesise_event(ev)
                    fout.write(json.dumps(ev, separators=(",", ":")) + "\n")
                    events_ok += 1
                except Exception as exc:
                    events_bad += 1
                    sys.stderr.write(
                        f"  per-event error #{events_ok + events_bad}: {exc}\n"
                    )
        except ijson.JSONError as exc:
            stream_err = str(exc)
    return events_ok, events_bad, stream_err


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--project", required=True, help="GCP project ID")
    ap.add_argument("--start", required=True, type=parse_date,
                    help="Inclusive start date YYYY-MM-DD (UTC)")
    ap.add_argument("--end", required=True, type=parse_date,
                    help="Exclusive end date YYYY-MM-DD (UTC)")
    ap.add_argument("--window", default="1d", type=parse_window,
                    help="Time-window size, N + 'h' or 'd' (default 1d)")
    ap.add_argument("--filter", default="",
                    help="Extra gcloud filter AND'd with the timestamp range")
    ap.add_argument("--output", required=True,
                    help="Final concatenated JSONL output path")
    ap.add_argument("--work-dir", required=True,
                    help="Per-run work dir for per-window raw+jsonl; re-use to resume")
    args = ap.parse_args()

    if args.end <= args.start:
        sys.stderr.write("--end must be > --start\n")
        sys.exit(2)

    work_dir = pathlib.Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    total_ok = 0
    total_bad = 0
    skipped = 0
    ran = 0
    aborted = False

    for win_start, win_end in windows(args.start, args.end, args.window):
        # Filesystem-safe tag: ISO timestamps without `:` (Windows-friendly).
        tag = f"{iso(win_start).replace(':', '')}_{iso(win_end).replace(':', '')}"
        raw_path = work_dir / f"{tag}.json"
        err_path = work_dir / f"{tag}.err"
        jsonl_path = work_dir / f"{tag}.jsonl"
        done_marker = work_dir / f"{tag}.done"

        if done_marker.exists() and jsonl_path.exists():
            skipped += 1
            sys.stderr.write(f"[skip] {tag} already done\n")
            continue

        sys.stderr.write(f"[run]  {tag} ...\n")
        ok, reason = run_gcloud(
            args.project, args.filter, win_start, win_end, raw_path, err_path,
        )
        if not ok:
            sys.stderr.write(f"[fail] {tag}: {reason}\n")
            aborted = True
            break

        events_ok, events_bad, stream_err = convert_window(raw_path, jsonl_path)
        ran += 1
        total_ok += events_ok
        total_bad += events_bad
        sys.stderr.write(
            f"       converted: {events_ok} ok, {events_bad} per-event errors\n"
        )
        if stream_err:
            sys.stderr.write(
                f"[warn] {tag}: stream error after {events_ok} events: {stream_err}\n"
                f"       partial JSONL kept at {jsonl_path}; window NOT marked done.\n"
            )
            # Leave done_marker absent so the next run retries this window.
            continue

        done_marker.touch()

        # Reclaim disk -- the raw .json is now redundant after the
        # window is .done. Keep the .err for incident inspection.
        if raw_path.exists():
            raw_path.unlink()

    # Concatenate all per-window JSONL in chronological order (sorted
    # filename = sorted timestamp because the tag is ISO).
    sys.stderr.write("[cat]  building final JSONL ...\n")
    jsonl_files = sorted(work_dir.glob("*.jsonl"))
    bytes_written = 0
    with open(args.output, "wb") as out_fh:
        for jp in jsonl_files:
            with open(jp, "rb") as fh:
                while True:
                    chunk = fh.read(1024 * 1024)
                    if not chunk:
                        break
                    out_fh.write(chunk)
                    bytes_written += len(chunk)

    sys.stderr.write(
        "\nSummary\n"
        "-------\n"
        f"  windows run this invocation:  {ran}\n"
        f"  windows skipped (already done): {skipped}\n"
        f"  events converted ok:          {total_ok}\n"
        f"  per-event errors (skipped):   {total_bad}\n"
        f"  final JSONL bytes:            {bytes_written}\n"
        f"  final JSONL path:             {args.output}\n"
    )

    if aborted:
        sys.stderr.write(
            "\nABORTED before completing the full date range.\n"
            "Most common cause: gcloud token expired (`ERROR: Reauthentication\n"
            "failed.` in the latest .err file).\n\n"
            "Refresh auth and re-run the SAME command. Completed windows are\n"
            "skipped; only the failing window forward is re-attempted.\n\n"
            "  gcloud auth login    # or activate-service-account --key-file=...\n"
            "  python gcp_export_to_ts.py ...  # same args as before\n"
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
